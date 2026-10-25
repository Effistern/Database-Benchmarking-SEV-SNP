#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------
# Variables
# -----------------------------------------------------------------

CONFIG=""
REGIME=""
ROUND=""
START="0.01"
MAXTCR="2.0"
FACTOR="2"
OPERATIONS="20000"
WARMUP_OPS="0"
MAX_DISK_UTIL="95"
OUT="./raw_results"
WORKLOAD="ldbc-rw"
REFINE=0

SELF_DIR="$(dirname "$(readlink -f "$0")")"
RUNNER="$SELF_DIR/run_benchmark.sh"
LOG="/var/log/neo4j_tcr_calibration.log"
# -----------------------------------------------------------------
# Parsing
# -----------------------------------------------------------------

while (($#)); do
  case "$1" in
  --config)
    CONFIG="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --regime)
    REGIME="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --round)
    ROUND="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --start-tcr)
    START="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --max-tcr)
    MAXTCR="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --operations)
    OPERATIONS="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --warm-up)
    WARMUP_OPS="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --out)
    OUT="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --refine)
    REFINE=1
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

case "$REGIME" in
resident | exceeding) ;;
"")
  echo "ERROR: --regime required" >&2
  exit 2
  ;;
*)
  echo "ERROR: --regime must be resident|exceeding" >&2
  exit 2
  ;;
esac

if [[ ! "$WARMUP_OPS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --regime required" >&2
  exit 2
fi

if [[ ! -x "$RUNNER" ]]; then
  echo "ERROR: benchmark script not found or not executable" >&2
  exit 2
fi

command -v python3 >/dev/null 2>&1 ||
  {
    echo "ERROR: Python required"
    exit 2
  }

OUT="$(readlink -f "$OUT")"
CAMPAIGN="$OUT/$ROUND"
mkdir -p "$CAMPAIGN"
SUMMARY="$CAMPAIGN/tcr_search.tsv"

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

floatMultiply() {
  python3 -c "print(f'{ float('$1') * float('$2'):.6g}')"
}
floatGreaterThan() {
  python3 -c "import sys; sys.exit(0 if float('$1') > float('$2') else 1)"
}

floatGeometricMean() {
  python3 -c "print(f'{(float('$1')*float('$2')) ** 0.5:.6g}')"
}

probe() {
  local tcr="$1" tag="$2"
  local before after newdir result SCRIPT_DIR

  before="$(find "$CAMPAIGN" -maxdepth 1 -type d -name '2*' 2>/dev/null | wc -l)"

  local args=(--config "$CONFIG" --regime "$REGIME" --round "$ROUND" --tcr "$tcr"
    --operations "$OPERATIONS" --warmup-operations "$WARMUP_OPS"
    --reps 1 --out "$OUT")

  if ! "$RUNNER" "${args[@]}" >"$CAMPAIGN/probe_${tag}.log" 2>&1; then
    log "Run failed , check ${CAMPAIGN}/probe_${tag}.log"
    return 1
  fi

  after="$(find "$CAMPAIGN" -maxdepth 1 -type d -name '2*' 2>/dev/null | wc -l)"
  if [[ ! "$after" -gt "$before" ]]; then
    log "Probe at ${tcr} did not produce a run directory"
    return 1
  fi

  newdir="$(find "$CAMPAIGN" -maxdepth 1 -type d -name '2*' -printf '%T@ %p\n' |
    sort -rn | head -1 | cut -d' ' -f2-)"

  SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
  result="$(python3 "$SCRIPT_DIR/tcr_check.py" "$newdir" "$MAX_DISK_UTIL")"
  if [[ "$result" == error* ]]; then
    log "Probe had no os_summary, saturation cannot be judged"
    return 1
  fi
  echo "$result"
}

record() {
  if [[ ! -f $SUMMARY ]]; then
    printf 'tcr\tverdict\tlate\ttotal\tlate_pct\tmean_us\tdisk_util_pct\n' >"$SUMMARY"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >>"$SUMMARY"
  fi
}

touch "$LOG"

# -----------------------------------------------------------------
# Calibration
# -----------------------------------------------------------------

log " TCR calibration config: $CONFIG, regime: $REGIME, workload: $WORKLOAD
      tests at $OPERATIONS operations (+$WARMUP_OPS warmup ops), 1 rep"

FIRST_PASS=""
LAST_FAIL=""
N=0
TCR="$START"

while :; do
  if floatGreaterThan "$TCR" "$MAXTCR"; then
    log "Reached maxtcr of $MAXTCR, no passing TCR found"
    break
  fi
  N=$((N + 1))
  log "Test $N: TCR of ${TCR}"

  if ! RESULT="$(probe "$TCR" "$(printf '%02d_%s' "$N" "$TCR")")"; then
    die "Probe could not be evaluated"
  fi

  read -r VERDICT LATE TOTAL MEAN UTIL <<<"$RESULT"
  PCT="n/a"
  if [[ "$TOTAL" =~ ^[0-9]+$ && "$TOTAL" -gt 0 && "$LATE" =~ ^[0-9]+$ ]]; then
    PCT="$(python3 -c "print(f'{100*$LATE/$TOTAL:.1f}')")"
  fi
  log " Verdict: ${VERDICT}"
  record "$TCR" "$VERDICT" "$LATE" "$TOTAL" "$PCT" "$MEAN" "$UTIL"
  if [[ "$VERDICT" == "pass" ]]; then
    FIRST_PASS="$TCR"
    break
  fi
  LAST_FAIL="$TCR"
  TCR="$(floatMultiply "$TCR" "$FACTOR")"
done

# -----------------------------------------------------------------
# Refining TCR
# -----------------------------------------------------------------

if [[ "$REFINE" -eq 1 && -n "$FIRST_PASS" && -n "$LAST_FAIL" ]]; then
  log "Refining between failed TCR $LAST_FAIL and passed TCR $FIRST_PASS"
  LO="$LAST_FAIL"
  HI="$FIRST_PASS"
  for i in 1 2 3; do
    MID=$(floatGeometricMean "$LO" "$HI")
    N=$((N + 1))
    if ! RESULT="$(probe "$MID" "$(printf '%02d_%s' "$N" "$MID")")"; then
      log "Refining failed"
      break
    fi
    read -r VERDICT LATE TOTAL MEAN UTIL <<<"$RESULT"
    PCT="n/a"
    if [[ "$TOTAL" =~ ^[0-9]+$ && "$TOTAL" -gt 0 && "$LATE" =~ ^[0-9]+$ ]]; then
      PCT="$(python3 -c "print(f'{100*$LATE/$TOTAL:.1f}')")"
    fi
    log " Verdict: ${VERDICT} with TCR of ${MID}"
    record "$TCR" "$VERDICT" "$LATE" "$TOTAL" "$PCT" "$MEAN" "$UTIL"
    if [[ "$VERDICT" == "pass" ]]; then
      HI="$MID"
    else
      LO="$MID"
    fi
  done
  FIRST_PASS="$HI"
fi

if [[ -z "$FIRST_PASS" ]]; then
  log "No passing TCR found below ${MAXTCR}, with the last failing being ${LAST_FAIL} check what is causing the saturation"
else
  log "Lowest passing TCR ${FIRST_PASS} (Config: ${CONFIG}, Regime: ${REGIME})"
fi
