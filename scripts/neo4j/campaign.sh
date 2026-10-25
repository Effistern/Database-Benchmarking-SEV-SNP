#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------
# Variables
# -----------------------------------------------------------------

ARGV=("$@")
DETACH=0
CONFIG=""
REGIMES="resident,exceeding"
REPS=12
ROUND="campaign"
OUT_ROOT="./raw_results"

PARAMS_RESIDENT="1    0.04  4000  20000"
PARAMS_EXCEEDING="10  0.1   500   6000"

STATE="/var/lib/db-benchmark"
PROPS_ROOT="/etc/db-benchmark"
DATA_MOUNT="/mnt/dbdata"
MIN_FREE_MB=5120

# -----------------------------------------------------------------
# Parsing
# -----------------------------------------------------------------

while (($#)); do
  case "$1" in
  --config)
    CONFIG="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --regimes)
    REGIMES="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --repetitions)
    REPS="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --round)
    ROUND="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --out)
    OUT_ROOT="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --detach)
    DETACH=1
    shift
    ;;
  *)
    echo "ERROR: Unknow argument: $1" >&2
    exit 2
    ;;
  esac
done

case "$CONFIG" in
none | sev | snp) ;;
"")
  echo "ERROR: --config required" >&2
  exit 2
  ;;
*)
  echo "ERROR: --config must be none|sev|snp" >&2
  exit 2
  ;;
esac

if ((DETACH)) && [[ -z "${CAMPAIGN_DETACHED:-}" ]]; then
  UNIT="campaign-neo4j-${CONFIG}-$(date -u +%Y%m%dT%H%M%SZ)"
  SELF="$(readlink -f "$0")"
  command -v systemd-run >/dev/null 2>&1 ||
    {
      echo "ERROR: systemd-run not found"
      exit 2
    }
  cat >&2 <<EOF
detaching as systemd unit: ${UNIT}

  status: systemctl status ${UNIT}
EOF

  exec systemd-run --unit="$UNIT" --working-directory="$PWD" \
    --setenv=CAMPAIGN_DETACHED=1 "$SELF" "${ARGV[@]}"
fi

WORKDIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LOG="${OUT_ROOT}/campaign_neo4j_${CONFIG}_$(date -u +%Y%m%dT%H%M%SZ).log"

# -----------------------------------------------------------------
# Helper
# -----------------------------------------------------------------

log() {
  echo "[$(date -u +%H:%M:%SZ)] $*" | tee -a "$LOG"
}

die() {
  log "ERROR: $*"
  exit 1
}

mkdir -p "$OUT_ROOT"
touch "$LOG"

finish() {
  local regime
  for regime in ${REGIMES_[@]+"${REGIMES_[@]}"}; do
    [[ -d "${OUT_ROOT}/${ROUND}__${r}" ]] || continue
    cp -f "$LOG" "${OUT_ROOT}/${ROUND}__${r}/campaign.log" 2>/dev/null || true
  done
}

trap finish EXIT

IFS=',' read -ra REGIMES_ <<<"$REGIMES"
for r in "${REGIMES_[@]}"; do
  case "$r" in
  resident | exceeding) ;;
  *)
    die "Unknow regime"
    ;;
  esac
done

regime_field() {
  local spec
  if [[ "$1" == resident ]]; then
    spec="$PARAMS_RESIDENT"
  else
    spec="$PARAMS_EXCEEDING"
  fi
  awk -v n="$2" '{print $n}' <<<"$spec"
}

# -----------------------------------------------------------------
# Pre check
# -----------------------------------------------------------------

log "Pre check: Config $CONFIG,  Regimes $REGIMES, REPS $REPS"

if [[ ! -x "${WORKDIR}/run_benchmark.sh" ]]; then
  die "run_benchmark.sh is missing"
fi

if [[ ! -x "${WORKDIR}/restore.sh" ]]; then
  die "restore.sh is missing"
fi

MICRO="${WORKDIR}/../common/run_microbench.sh"
if [[ ! -x "$MICRO" ]]; then
  die "Hardware control not found / tools not installed"
fi

mountpoint -q "$DATA_MOUNT" ||
  die "Data mount not found"

FREE_MB=$(($(df -P --block-size=1M "$DATA_MOUNT" | awk 'NR==2{print $4}')))
if ((FREE_MB < MIN_FREE_MB)); then
  die "Not enough free space on the decive"
fi

for r in "${REGIMES_[@]}"; do
  SF="$(regime_field "$r" 1)"
  snap="${STATE}/neo4j_dataset.sf${SF}"
  props="${PROPS_ROOT}/sf${SF}/ldbc-benchmark.properties"

  if [[ ! -f "$snap" ]]; then
    die "No state snapshot. Written by restore.sh --make-pristine"
  fi

  pristine_dir="$(awk -F= '/^pristine_dir=/{print $2}' "$snap")"
  if [[ ! (-n "$pristine_dir" && -d "$pristine_dir") ]]; then
    die "No pristine directory found for ${r}"
  fi

  if [[ ! -f "$props" ]]; then
    die "No properties found. Written by make_properties.sh"
  fi

  log "Pre check done: ${r}, SF ${SF}, TCR $(regime_field "$r" 2), Warmup $(regime_field "$r" 3), \
    operations $(regime_field "$r" 4)"
done

# -----------------------------------------------------------------
# Run
# -----------------------------------------------------------------

microbench() {
  local regime="$1" phase="$2"
  log "Hardware control ($phase, $regime)"
  if "$MICRO" --config "$CONFIG" --round "${ROUND}__${regime}" \
    --phase "$phase" --out "$OUT_ROOT"; then
    log "Hardware control ran"
  else
    log "Hardware control failed"
  fi
}

for r in "${REGIMES_[@]}"; do
  SF="$(regime_field "$r" 1)"
  TCR="$(regime_field "$r" 2)"
  WARMUP="$(regime_field "$r" 3)"
  OPS="$(regime_field "$r" 4)"
  PROPS="${PROPS_ROOT}/sf${SF}/ldbc-benchmark.properties"

  log "Regime ${r} SF ${SF}, TCR ${TCR}, Warmup ops ${WARMUP}, Oerations ${OPS}"

  cp "${STATE}/neo4j_dataset.sf${SF}" "${STATE}/neo4j_dataset" ||
    die "Could not switch dataset file"
  microbench "$r" pre
  started="$(date -u +%s)"
  if "${WORKDIR}/run_benchmark.sh" --config "$CONFIG" --regime "$r" --round "${ROUND}__${r}" \
    --properties "$PROPS" --tcr "$TCR" --operations "$OPS" --warmup-operations "$WARMUP" \
    --reps "$REPS" --out "$OUT_ROOT"; then
    log "Rep $r completed in $((($(date -u +%s) - started) / 60)) min"
  else
    log "Rep $r failed after $((($(date -u +%s) - started) / 60)) min"
    log "Continuing to the next regime"
  fi

  microbench "$r" post
done

log "Campaign complete"
