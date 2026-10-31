#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------
# Variables
# -----------------------------------------------------------------

CONFIG=""
ROUND=""
PHASE=""
REPS=3
CPU_MAX_PRIME=20000
CPU_EVENTS=10000
MEM_TOTAL="8G"
MEM_BLOCK="1K"
CORES="1,3"
DB_CORES="0,2"
USE_DB_CORES=1
OUT=""
# -----------------------------------------------------------------
# Parsing
# -----------------------------------------------------------------

while (($#)); do
  case "$1" in
  --config)
    CONFIG="${2:?Missing value for --config}"
    shift 2
    ;;
  --round)
    ROUND="${2:?Missing value for --round}"
    shift 2
    ;;
  --phase)
    PHASE="${2:?Missing value for --phase}"
    shift 2
    ;;
  --out)
    OUT="${2:?Missing value for --out}"
    shift 2
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

if [[ -z "$ROUND" ]]; then
  echo "ERROR: --round required" >&2
  exit 2
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
CAMPAIGN="${OUT}/${ROUND}/${TS}__microbench__${CONFIG}__${PHASE}"
mkdir -p "$CAMPAIGN/runs"
LOG="$CAMPAIGN/run.log"

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

command -v sysbench >/dev/null 2>&1 ||
  die "sysbench not installed"

command -v python3 >/dev/null 2>&1 ||
  die "python3 not installed"

# -----------------------------------------------------------------
# Microbench
# -----------------------------------------------------------------

cpu_idle_pct() {
  mpstat "${1:-2}" 1 | awk '/Average:/ && $NF ~ /^[0-9.]+$/ { printf "%.0f\n", $NF}'
}

IDLE_PCT="$(cpu_idle_pct 2)"
if ((IDLE_PCT < 95)); then
  log "Machine not fully idle"
fi

log "Microbenchmark config: ${CONFIG}, round: ${ROUND}, phase: ${PHASE}, reps: ${REPS}"
log "Cores: ${CORES}"

JOBS=(
  "cpu_1t|cpu --cpu-max-prime=${CPU_MAX_PRIME} --threads=1 --events=${CPU_EVENTS}"
  "cpu_2t|cpu --cpu-max-prime=${CPU_MAX_PRIME} --threads=2 --events=${CPU_EVENTS}"
  "mem_seq_read_1t|memory --memory-total-size=${MEM_TOTAL} --memory-block-size=${MEM_BLOCK} --memory-oper=read --memory-access-mode=seq --threads=1"
  "mem_rnd_read_1t|memory --memory-total-size=${MEM_TOTAL} --memory-block-size=${MEM_BLOCK} --memory-oper=read --memory-access-mode=rnd --threads=1"
  "mem_seq_write_1t|memory --memory-total-size=${MEM_TOTAL} --memory-block-size=${MEM_BLOCK} --memory-oper=write --memory-access-mode=seq --threads=1"
  "mem_rnd_write_1t|memory --memory-total-size=${MEM_TOTAL} --memory-block-size=${MEM_BLOCK} --memory-oper=write --memory-access-mode=rnd --threads=1"
)

if [[ "$USE_DB_CORES" -eq 1 && "$DB_CORES" != "$CORES" ]]; then
  JOBS+=("cpu_1t_dbcores|cpu --cpu-max-prime=${CPU_MAX_PRIME} --threads=1 --events=${CPU_EVENTS}")
fi

FAILED=0

for rep in $(seq 1 "$REPS"); do
  for job in "${JOBS[@]}"; do
    name="${job%%|*}"
    args="${job#*|}"
    out="$CAMPAIGN/runs/$(printf '%s__r%02d' "$name" "$rep")"
    pin_cmd="$CORES"
    if [[ "$name" == *_dbcores ]]; then
      pin_cmd="$DB_CORES"
    fi
    printf 'taskset -c %s sysbench %s run\n' "$pin_cmd" "$args" >"${out}.command"
    pin="$CORES"
    if [[ "$name" == *_dbcores ]]; then
      pin="$DB_CORES"
    fi
    if taskset -c "$pin" sysbench $args run >"${out}.stdout" 2>"${out}.stderr"; then
      :
    else
      log "Job ${name} failed, check ${out}.stderr"
      FAILED=$((FAILED + 1))
    fi
    sleep 1
  done
  log "Repetition ${rep}/${REPS} done"
done

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
python3 "$SCRIPT_DIR/microbench_summary.py" "$CAMPAIGN/runs" "$CAMPAIGN/summary.csv" \
  "$CAMPAIGN/summary.txt" "$CONFIG" "$ROUND" "$PHASE" "$MEM_BLOCK"

if [[ ! "$FAILED" -eq 0 ]]; then
  die "Failed job exist abort run"
fi
log "Microbenchmark done"
