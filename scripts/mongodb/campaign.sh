#!/usr/bin/env bash
set -euo pipefail

ARGV=("$@")
DETACH=0

source "$(dirname "$(readlink -f "$0")")/lib.sh"

#--------------------------------------------------------
#Variables
#--------------------------------------------------------

CONFIG=""
REGIMES="resident,exceeding"
WORKLOADS="a,b,c,d,e,f"
REPS=12
ROUND="campaign"
OUT_ROOT="./raw_results"
POWEROFF=0
MICROBENCH=1

OPS_RESIDENT="default=3000000,e=500000"
WARMUP_RESIDENT="default=1500000,d=3000000,e=250000"
OPS_EXCEEDING="default=1500000,d=2000000,e=45000"
WARMUP_EXCEEDING="default=200000,e=20000"

DATA_MOUNT="/mnt/dbdata"
STATE="/var/lib/db-benchmark"
MIN_FREE_MB=5120

#--------------------------------------------------------
#Argument Parsing
#--------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)               CONFIG="${2:?--config requires a value}";           shift 2 ;;
    --regimes)              REGIMES="${2:?--regimes requires a value}";          shift 2 ;;
    --workloads)            WORKLOADS="${2:?--workloads requires a value}";        shift 2 ;;
    --repetitions)          REPS="${2:?--repetitions requires a value}";             shift 2 ;;
    --round)                ROUND="${2:?--round requires a value}";            shift 2 ;;
    --out)                  OUT_ROOT="${2:?--out requires a value}";         shift 2 ;;
    --ops-resident)         OPS_RESIDENT="${2:?--ops-resident requires a value}";     shift 2 ;;
    --warmup-resident)      WARMUP_RESIDENT="${2:?--warmup-resident requires a value}";  shift 2 ;;
    --ops-exceeding)        OPS_EXCEEDING="${2:?--ops-exceeding requires a value}";    shift 2 ;;
    --warmup-exceeding)     WARMUP_EXCEEDING="${2:?--warmup-exceeding requires a value}"; shift 2 ;;
    --detach)               DETACH=1;                             shift   ;;
    --no-microbench)        MICROBENCH=0;                         shift   ;;
    --dry-run)              DRY_RUN=1;                            shift   ;;
    --poweroff-on-success)  POWEROFF=1;                           shift   ;;
    *)                      echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

validate_config "$CONFIG"

#--------------------------------------------------------
#Detach-mech
#--------------------------------------------------------

if (( DETACH )) && [[ -z "${CAMPAIGN_DETACHED:-}" ]]; then
  UNIT="campaign-mongodb-${CONFIG}-$(date -u +%Y-%m-%dT%H%M%SZ)"
  SELF="$(readlink -f "$0")"
  command -v systemd-run >/dev/null 2>&1 ||
          { echo "ERROR: --detach needs systemd-run, which is not installed" >&2; exit 2; }
  cat >&2 <<EOF

  detaching as systemd unit: ${UNIT}

    status: systemctl status ${UNIT}
EOF
         exec systemd-run --unit="$UNIT" \
                    --working-directory="$PWD" \
                    --setenv=CAMPAIGN_DETACHED=1 \
                    "$SELF" "${ARGV[@]}"
fi


#--------------------------------------------------------
#Logging and Cleanup
#--------------------------------------------------------
WORKDIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
mkdir -p "$OUT_ROOT"
BENCH_LOG="${OUT_ROOT}/campaign_${CONFIG}_$(date -u +%Y-%m-%dT%H%M%SZ).log"
lib_init

finish() {
  local r
  for r in ${REGIMES_[@]+"${REGIMES_[@]}"}; do
      [[ -d "${OUT_ROOT}/${ROUND}__${r}" ]] || continue
      cp -f "$BENCH_LOG" "${OUT_ROOT}/${ROUND}__${r}/campaign.log" 2>/dev/null || true
    done
}
trap finish EXIT

IFS=',' read -ra REGIMES_ <<<"$REGIMES"
for r in "${REGIMES_[@]}"; do
  validate_regime "$r"
done


IFS=',' read -ra WORKLOADS_ <<<"$WORKLOADS"
NWL=${#WORKLOADS_[@]}

regime_ops()    { [[ "$1" == resident ]] && echo "$OPS_RESIDENT" || echo "$OPS_EXCEEDING"; }
regime_warmup() { [[ "$1" == resident ]] && echo "$WARMUP_RESIDENT" || echo "$WARMUP_EXCEEDING"; }

#--------------------------------------------------------
#Precheck
#--------------------------------------------------------

log "Precheck: config=${CONFIG} regimes=${REGIMES} workloads=${WORKLOADS} reps=${REPS}"

[[ -x "${WORKDIR}/run_benchmark.sh" ]] ||
  die "run_benchmark.sh not found or not executable in ${WORKDIR}"


MICRO="${WORKDIR}/../common/run_microbench.sh"
if (( MICROBENCH )); then
  [[ -x "$MICRO" ]] ||
    die "hardware control enabled but ${MICRO} is missing or not executeable"
    require_cmd sysbench
    log "Precheck: hardware control enabled (${MICRO})"
else
    log "Precheck: WARNING -- hardware control DISABLED"
fi

require_mount "$DATA_MOUNT"
require_mongod

source_ycsb_profile
for w in "${WORKLOADS_[@]}"; do
  [[ -f "$YCSB_HOME/workloads/workload${w}" ]] ||
    die "no YCSB workload for '${w}'"
done

FREE_MB="$(free_mb_on "$DATA_MOUNT")"
(( FREE_MB >= MIN_FREE_MB )) ||
  die "only ${FREE_MB} MB free on ${DATA_MOUNT}, want at least ${MIN_FREE_MB} MB"
log "Precheck: ${FREE_MB} MB free on ${DATA_MOUNT}"

for r in "${REGIMES_[@]}"; do
  snap="${STATE}/mongodb_dataset.${r}"
  [[ -f "$snap" ]] ||
    die "no state snapshot ${snap}."

  did="$(awk -F= '/^dataset_id=/{print $2}' "$snap")"
  [[ -n "$did" ]] || die "no dataset_id in ${snap}"

  pristine="${DATA_MOUNT}/pristine_${did}"
  [[ -d "$pristine" ]] ||
    die "regime '${r} needs ${pristine}"

  Id="$(awk -F= '/^load_dir=/{print $2}' "$snap")"
  if [[ ! -f "${Id}/dataset_manifest.json" ]]; then
      log "WARNING: ${Id}/dataset_manifest.json doesnt exist"
  fi

  log "Precheck: ${r} -> ${did} ($(du -sm "$pristine" | awk '{print $1}') MB pristine)"

done

for r in "${REGIMES_[@]}"; do
    [[ ! -e "${OUT_ROOT}/${ROUND}__${r}" ]] ||
      die "${OUT_ROOT}/${ROUND}__${r} already exists."
done
#--------------------------------------------------------
#Run
#--------------------------------------------------------

microbench() {
  local regime="$1" phase="$2"
  (( MICROBENCH )) || return 0
  log "hardware control (${phase}) --regime ${regime}"
  if "$MICRO" --config "$CONFIG" --round "${ROUND}__${regime}" --phase "$phase" --out "$OUT_ROOT"; then
    log " hardware control ${phase}: ok"
  else
    log " WARNING: hardware control ${phase} FAILED for regime ${regime} --"
  fi
}

declare -A RESULT=()
FAILED=0

for r in "${REGIMES_[@]}"; do
  log "regime ${r}: starting $(( NWL * REPS )) runs"

  cp "${STATE}/mongodb_dataset.${r}" "${STATE}/mongodb_dataset" ||
    die "could not switch the state file to ${r}"

    microbench "$r" pre

    started="$(date -u +%s)"
    if "${WORKDIR}/run_benchmark.sh" \
                    --config "$CONFIG" \
                    --regime "$r" \
                    --round "${ROUND}__${r}" \
                    --workloads "$WORKLOADS" \
                    --repetitions "$REPS" \
                    --operations "$(regime_ops "$r")" \
                    --warmup-operations "$(regime_warmup "$r")" \
                    --out "$OUT_ROOT"; then
          RESULT[$r]="ok"
          log "regime ${r}: COMPLETED in $(( ($(date -u +%s) -started) / 60 )) min"
    else
      rc=$?
      RESULT[$r]="FAILED (exit ${rc})"
      FAILED=1
      log "regime ${r}: FAILED with exit ${rc} after $(( ( $(date -u +%s) - started) / 60)) min"
    fi
    microbench "$r" post
done

#--------------------------------------------------------
#Summary
#--------------------------------------------------------

log "Summary: config=${CONFIG}"
for r in "${REGIMES_[@]}"; do
    n=$(find "${OUT_ROOT}/${ROUND}__${r}" -maxdepth 1 -name '*__r*' -type d 2>/dev/null | wc -l)
    log " ${r}: ${RESULT[$r]} -- ${n - 1} of $(( NWL * REPS )) run directories"
done

GLOB=("${OUT_ROOT}/${ROUND}__"*/*/os_summary.json)
CRIT=0; WARN=0
if [[ -e "${GLOB[0]}" ]]; then
    CRIT=$({ grep -l -e 'db_cpu_pct is ~0' -e 'RSS is identical' "${GLOB[@]}" 2>/dev/null || true;} | wc -l)
    WARN=$({ grep -L '"warnings": \[\]' "${GLOB[@]}" 2>/dev/null || true;} | wc -l)
fi

if (( CRIT > 0 )); then
    log "  ${CRIT} run(s) have KNOWN-BAD process metrics"
fi

if (( WARN > CRIT )); then
    log "  $(( WARN - CRIT )) run(s) carry operating-point warnings"
fi

if (( WARN == 0 )); then
    log "  no warnings on any run"
fi

if (( FAILED )); then
  log " campaign finished with a FAILED regime -- NOT powering off"
  exit 1
fi

if (( CRIT > 0 )); then
  log " every regime completed, but ${CRIT} run(s) are unusable -- NOT powering off"
  exit 1
fi

if (( POWEROFF )); then
  log " all regime usable; syncing and powering off in 60 s (ctrl-C or 'sudo systemctl stop' to cancel)"
  sync
  sleep 60
  log "powering off"
  shutdown -h now
fi

log "campaign complete"
exit 0