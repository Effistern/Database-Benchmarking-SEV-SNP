#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------
# Variables
# -----------------------------------------------------------------

CONFIG=""
REGIME=""
ROUND=""
PROPERTIES=""
TCR=""
OPERATION=""
WARMUP_OPS=""
REPS=""
THREADS=2
DRIVER_CORES="1,3"
COOLDOWN=60
MIN_IOWAIT_PCT=1
MIN_READ_IOPS=100
OUT="./raw_results"
SAMPLE_INTERVAL=1
DATA_MOUNT="/mnt/dbdata"
LDBC_HOME="/opt/ldbc-snb-interactive-v1"
DRIVER_JAVA_HOME="/usr/lib/jvm/java-11-openjdk-amd64"

# -----------------------------------------------------------------
# Parsing
# -----------------------------------------------------------------

while (($#)); do
  case "$1" in
  --config)
    CONFIG="${2:?Missing value for --config}"
    shift 2
    ;;
  --regime)
    REGIME="${2:?Missing value for --regime}"
    shift 2
    ;;
  --round)
    ROUND="${2:?Missing value for --round}"
    shift 2
    ;;
  --properties)
    PROPERTIES="${2:?Missing value for --tcr}"
    shift 2
    ;;
  --tcr)
    TCR="${2:?Missing value for --tcr}"
    shift 2
    ;;
  --operations)
    OPERATION="${2:?Missing value for --prisitine-dir}"
    shift 2
    ;;
  --warmup-operations)
    WARMUP_OPS="${2:?Missing value for --prisitine-dir}"
    shift 2
    ;;
  --reps)
    REPS="${2:?Missing value for --prisitine-dir}"
    shift 2
    ;;
  --out)
    OUT="${2:?Missing value for --prisitine-dir}"
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
if [[ -z "$ROUND" ]]; then
  echo "ERROR: --round required" >&2
  exit 2
fi

if [[ -z "$REPS" ]]; then
  echo "ERROR: --round required" >&2
  exit 2
fi

if [[ ! ("$WARMUP_OPS" =~ ^[0-9]+$) ]]; then
  echo "ERROR: --warmup-operations require a whole number" >&2
  exit 2
fi

mkdir -p "$OUT" 2>/dev/null || true
OUT="$(cd "$OUT" 2>/dev/null && pwd)" ||
  {
    echo "ERROR: --out could not be created" >&2
    exit 2
  }

if [[ -z "$PROPERTIES" ]]; then
  PROPERTIES="$(awk -F= '/^benchmark_properties=/{print $2}' \
    /var/lib/db-benchmark/ldbc_properties 2>/dev/null || true)"
fi

if [[ -z "$PROPERTIES" ]]; then
  echo "ERROR: --properties required (no file found)"
fi

if [[ -z "$TCR" ]]; then
  echo "ERROR: --tcr required"
fi

# -----------------------------------------------------------------
# Helper
# -----------------------------------------------------------------

STATE="/var/lib/db-benchmark"
LOG="/var/log/neo4j_benchmark.log"
GCLOG="/var/log/neo4j/gc.log"
SAMPLER_PIDS=()

log() {
  echo "[$(date -u +%H:%M:%SZ)] $*" | tee -a "$LOG"
}

die() {
  log "ERROR: $*"
  exit 1
}

source "$(dirname "$(readlink -f "$0")")/../common/bench_helper.sh"

stop_samplers() {
  for sampler in "${SAMPLER_PIDS[@]:-}"; do
    if [[ -n "$sampler" ]]; then
      kill "$sampler" 2>/dev/null || true
    fi
  done
  SAMPLER_PIDS=()
  wait 2>/dev/null || true
}

trap stop_samplers EXIT

check_samplers() {
  local missing=()
  for tool in sar iostat pidstat vmstat; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if ((${#missing[@]} == 0)); then
    return 0
  fi
  die "Missing samplers, not installed: ${missing[*]}"
}

start_samplers() {
  local dir="$1" neopid="$2"
  mkdir -p "$dir"
  sar -u -r -b -w -q "$SAMPLE_INTERVAL" >"$dir/sar.txt" 2>&1 &
  SAMPLER_PIDS+=($!)
  iostat -x -t "$SAMPLE_INTERVAL" >"$dir/iostat.txt" 2>&1 &
  SAMPLER_PIDS+=($!)
  vmstat -t "$SAMPLE_INTERVAL" >"$dir/vmstat.txt" 2>&1 &
  SAMPLER_PIDS+=($!)
  if [[ "${neopid:-0}" -gt 0 ]]; then
    pidstat -p "$neopid" -u -r- -d -h "$SAMPLE_INTERVAL" >"$dir/pidstat_neo4j.txt" 2>&1 &
    SAMPLER_PIDS+=($!)
  fi
}

mkdir -p "$STATE"
touch "$LOG"

log "Checking guards: "

# ---------------------------------------------------------------------------
# guards
# ---------------------------------------------------------------------------

RESTORE_SH="$(dirname "$(readlink -f "$0")")/restore.sh"
EXCEEDING_CHECK="$(dirname "$(readlink -f "$0")")/../common/check_exceeding.py"
WORKLOAD="ldbc-rw"

if [[ ! -x "$RESTORE_SH" ]]; then
  die "restore.sh not available, benchmark modifies DB, not same starting point"
fi

log "Running the full Interactive workload"
log "The database will be restored before every repetition"

if [[ ! -f "$STATE/neo4j_setup" ]]; then
  die "install_neo4j.sh run required before this"
fi

if [[ ! -f "$STATE/ldbc_install" ]]; then
  die "install_ldbc.sh run required before this"
fi

log "Driver JVM: $DRIVER_JAVA_HOME"

NEO_PID="$(systemctl show neo4j.service -p MainPID --value 2>/dev/null || echo 0)"

if [[ ! "${NEO_PID:-0}" -gt 0 ]]; then
  die "Neo4j not running"
fi

command -v cypher-shell >/dev/null 2>&1 ||
  die "cypher-shell not available"

SCALE_FACTOR="$(awk -F= '/^scale_factor=/{print $2}' "$STATE/neo4j_dataset" 2>/dev/null || true)"
if [[ -z "$SCALE_FACTOR" ]]; then
  die "No scale_factor in neo4j_dataset"
fi
DATASET="SF${SCALE_FACTOR}"

# ---------------------------------------------------------------------------
# Regime check
# ---------------------------------------------------------------------------

STORE_MIB="$(awk -F= '/^pristine_bytes=/{print int($2/1048576)}' "$STATE/neo4j_dataset" 2>/dev/null || true)"
PAGECACHE_MIB="$(awk -F= '/^pagecache=/{print int($2*1024)}' "$STATE/neo4j_setup" 2>/dev/null || true)"
MEM_MIB=$(($(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024))

if [[ -z "$STORE_MIB" || -z "$PAGECACHE_MIB" ]]; then
  die "Could not read store nor page cache size, cant verify regime"
else
  log "Regime check: ${STORE_MIB} MiB, page cache ${PAGECACHE_MIB} MiB, MemTotal ${MEM_MIB}"
  case "$REGIME" in
  resident)
    if ((STORE_MIB > PAGECACHE_MIB)); then
      die "Stored MiB bigger than neo4j page cache -> Not resident"
    fi
    ;;
  exceeding)
    if ((STORE_MIB < MEM_MIB)); then
      die "Stored MiB smaller than MemTotal -> Not exceeding"
    fi
    ;;
  esac
fi

DATA_DEVICE="$(data_disk_device "$DATA_MOUNT")" ||
  die "Mount not found"

CAMPAIGN="${OUT}/${ROUND}"
mkdir -p "$CAMPAIGN"

LOAD_AVG="$(awk '{print $1}' /proc/loadavg)"
log "LDBC workload: config=$CONFIG, regime=$REGIME ($DATASET), round=$ROUND, tcr=$TCR"
log "reps=$REPS, ${OPERATION} measured ops, ${WARMUP_OPS} warm-up ops, ${THREADS} threads"
log "data disk: ${DATA_DEVICE}"
log "Load average before the round ${LOAD_AVG}"

# ---------------------------------------------------------------------------
# Repetitions
# ---------------------------------------------------------------------------

FAILED=0
check_samplers
CYPHER_AUTH=(-u neo4j -p "${NEO4J_PASSWORD:-admin}")

for rep in $(seq 1 "$REPS"); do
  TS="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_DIR="${CAMPAIGN}/${TS}__neo4j__${CONFIG}__${REGIME}__${WORKLOAD}__r$(printf '%02d' "$rep")"
  log "Repetitions ${rep}/${REPS} -> ${RUN_DIR}"

  mkdir -p "$RUN_DIR/os_metrics" "$RUN_DIR/db_metrics" "$RUN_DIR/ldbc_results"
  PROPS="$RUN_DIR/driver.properties"
  {
    grep -vE '^[[:space:]]*(operation_count|warmup|thread_count|time_compression_ratio|results_dir|name)[[:space:]]*=' \
      "$PROPERTIES"
    printf '\n# --- overridden by run_benchmark.sh ---\n'
    printf 'operation_count=%s\n' "$OPERATION"
    printf 'warmup=%s\n' "$WARMUP_OPS"
    printf 'thread_count=%s\n' "$THREADS"
    printf 'time_compression_ratio=%s\n' "$TCR"
    printf 'results_dir=%s\n' "$RUN_DIR/ldbc_results"
    printf 'name=%s__%s__r%s\n' "$CONFIG" "$ROUND" "$rep"
  } >"$PROPS"
  cp -a "$PROPERTIES" "$RUN_DIR/driver.properties.base" 2>/dev/null || true

  log "Restoring database before rep ${rep}"
  RESTORE_START="$(date -u +%s)"
  if ! "$RESTORE_SH" >/dev/null 2>"$RUN_DIR/restore.err"; then
    die "Restore failed before rep ${rep}"
  fi
  RESTORE_SECONDS=$(($(date -u +%s) - RESTORE_START))
  log "Restore done in ${RESTORE_SECONDS}"

  sync
  echo 3 >/proc/sys/vm/drop_caches ||
    die "Could not OS page cache"
  sleep 2
  log "OS page cache dropped -> Same starting state"

  NEO_PID="$(largest_process_in_unit neo4j.service)" ||
    die "Could not find neo4j server process"
  assert_process_is_working "$NEO_PID" "neo4j"

  GC_OFFSET=0
  if [[ -f "$GCLOG" ]]; then
    GC_OFFSET="$(stat -c %s "$GCLOG")"
  fi

  start_samplers "$RUN_DIR/os_metrics" "$NEO_PID"
  MSTART="$(date -u +%s)"
  set +e
  log "Starting benchmark"
  taskset -c "$DRIVER_CORES" \
    env "JAVA_HOME=$DRIVER_JAVA_HOME" "PATH=$DRIVER_JAVA_HOME/bin:$PATH" \
    bash "$LDBC_HOME/cypher/driver/benchmark.sh" "$PROPS" \
    >"$RUN_DIR/driver.stdout" 2>"$RUN_DIR/driver.stderr"
  RC=$?
  set -e
  ELAPSED=$(($(date -u +%s) - MSTART))
  log "Benchmark ended after ${ELAPSED}s"
  stop_samplers

  summarise_run_os_metrics "$RUN_DIR" "$DATA_DEVICE"

  if [[ "$REGIME" == "exceeding" && "$rep" -eq 1 ]]; then
    RESULT="$(python3 "$EXCEEDING_CHECK" "$RUN_DIR/os_summary.json" \
      "$MIN_IOWAIT_PCT" "$MIN_READ_IOPS" 2>/dev/null)"

    case $RESULT in
    ok)
      log "Exceeding regime detected"
      ;;
    "not ok")
      log "Non exceeding regime detected"
      ;;
    esac
  fi
  if [[ -f "$GCLOG" ]]; then
    GC_NOW="$(stat -c %s "$GCLOG")"
    if [[ "$GC_NOW" -lt "$GC_OFFSET" ]]; then
      GC_OFFSET=0
    fi
    tail -c "+$((GC_OFFSET + 1))" "$GCLOG" >"$RUN_DIR/db_metrics/gc.log" 2>/dev/null || true
    if [[ ! -s "$RUN_DIR/db_metrics/gc.log" ]]; then
      log "gc.log is empty"
    fi
  else
    log "gc.log does not exist"
  fi
  SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
  cp -a "/etc/neo4j/neo4j.conf" "$RUN_DIR/db_metrics/neo4j.conf" 2>/dev/null || true
  python3 "$SCRIPT_DIR/parse_db_metrics.py" "$RUN_DIR" "$RC" \
    >"$RUN_DIR/db_metrics/parsed.json" \
    2>"$RUN_DIR/db_metrics/parse.err" || true

  PARSED="$RUN_DIR/db_metrics/parsed.json"
  OK=True
  if [[ "$RC" -ne 0 ]]; then
    OK=False
    FAILED=$((FAILED + 1))
    log "Driver exited non 0, failed run  +1"
  fi
  directory="$RUN_DIR/os_summary.json"
  python3 "$SCRIPT_DIR/write_manifest.py" "$RUN_DIR/manifest.json" \
    "$PARSED" \
    "$directory" \
    "$RUN_DIR" \
    "$TS" \
    "$ROUND" \
    "$CONFIG" \
    "$REGIME" \
    "$WORKLOAD" \
    "$rep" \
    "$OK" \
    "$DATA_DEVICE" \
    "$DATASET" \
    "$TCR" \
    "$OPERATION" \
    "$WARMUP_OPS" \
    "$THREADS" \
    "$DRIVER_CORES" \
    "$COOLDOWN" \
    "$SAMPLE_INTERVAL" \
    "$RESTORE_SECONDS" \
    "$ELAPSED" \
    "$STATE" \
    "$LDBC_HOME" \
    "$DRIVER_JAVA_HOME" \
    "$LOAD_AVG"
  MEAN="$(python3 -c "import json; d=json.load(open('$PARSED')); v=d.get('latency_mean_us'); print(f'{v:.1f}' if v else 'n/a')" 2>/dev/null || echo n/a)"
  log " Mean latency ${MEAN}us, completed in ${ELAPSED}"
done

log "All Repetitions done, ${FAILED} failed rounds"
if ((FAILED != 0)); then
  exit 1
fi
