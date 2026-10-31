#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/lib.sh"

#--------------------------------------------------------
#Configuration
#--------------------------------------------------------

CONFIG=""
REGIME=""
ROUND=""
WORKLOADS="a,b,c,d,e,f"
OPERATIONS=500000
WARMUP_OPS=200000
declare -A OPS_BY_WL=()
declare -A WU_BY_WL=()
RECORDS=""
THREADS=2
REPS=3
YCSB_CORES="1,3"
DBNAME="ycsb"
SAMPLE_INTERVAL=1
COLD=1
OUT_ROOT="./raw_results"
DRAIN_SECONDS=30
DO_DRAIN=1
DUMP_DIR=""
RESTORE_MODE="copy"
PRISTINE_DIR=""
DBPATH=""
VERIFY_METHOD=""
MIN_IOWAIT_PCT=1
MIN_READ_IOPS=100
DATA_MOUNT="/mnt/dbdata"
STATE="/var/lib/db-benchmark"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

#--------------------------------------------------------
#Parsing
#--------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
  --config)
    CONFIG="${2:?--config requires a value}"
    shift 2
    ;;
  --regime)
    REGIME="${2:?--regime requires a value}"
    shift 2
    ;;
  --round)
    ROUND="${2:?--round requires a value}"
    shift 2
    ;;
  --workloads)
    WORKLOADS="${2:?--workloads requires a value}"
    shift 2
    ;;
  --operations)
    OPERATIONS="${2:?--operations requires a value}"
    shift 2
    ;;
  --warmup-operations)
    WARMUP_OPS="${2:?--warmup-operations requires a value}"
    shift 2
    ;;
  --records)
    RECORDS="${2:?--records requires a value}"
    shift 2
    ;;
  --threads)
    THREADS="${2:?--threads requires a value}"
    shift 2
    ;;
  --repetitions | --repititions)
    REPS="${2:?--repetitions requires a value}"
    shift 2
    ;;
  --ycsb-cores)
    YCSB_CORES="${2:?--ycsb-cores requires a value}"
    shift 2
    ;;
  --db)
    DBNAME="${2:?--db requires a value}"
    shift 2
    ;;
  --restore-mode)
    RESTORE_MODE="${2:?--restore-mode requires a value}"
    shift 2
    ;;
  --pristine-dir)
    PRISTINE_DIR="${2:?--pristine-dir requires a value}"
    shift 2
    ;;
  --dbpath)
    DBPATH="${2:?--dbpath requires a value}"
    shift 2
    ;;
  --dump-dir)
    DUMP_DIR="${2:?--dump-dir requires a value}"
    shift 2
    ;;
  --sample-interval)
    SAMPLE_INTERVAL="${2:?--sample-interval requires a value}"
    shift 2
    ;;
  --drain-seconds)
    DRAIN_SECONDS="${2:?--drain-seconds requires a value}"
    shift 2
    ;;
  --no-drain)
    DO_DRAIN=0
    shift
    ;;
  --warm)
    COLD=0
    shift
    ;;
  --min-iowait-pct)
    MIN_IOWAIT_PCT="${2:?--min-iowait-pct requires a value}"
    shift 2
    ;;
  --min-read-iops)
    MIN_READ_IOPS="${2:?--min-read-iops requires a value}"
    shift 2
    ;;
  --out)
    OUT_ROOT="${2:?--out requires a value}"
    shift 2
    ;;
  *)
    echo "ERROR: Unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

validate_config "$CONFIG"
validate_regime "$REGIME"

if ! [[ -n "$ROUND" ]]; then
  echo "ERROR: --round required" >&2
  exit 2
fi

ROUND_DIR="${OUT_ROOT}/${ROUND}"
mkdir -p "$ROUND_DIR"
BENCH_LOG="${ROUND_DIR}/${CONFIG}_benchmark.log"
lib_init

#--------------------------------------------------------
#Help-functions
#--------------------------------------------------------
parse_counts() {
  local spec="$1" label="$4" part k v
  local -n _arr="$2"
  local -n _def="$3"

  if [[ "$spec" =~ ^[0-9]+$ ]]; then
    _def="$spec"
    return 0
  fi

  local -a parts
  IFS=',' read -ra parts <<<"$spec"
  for part in "${parts[@]}"; do
    [[ "$part" == *=* ]] ||
      die "${label}: '${part}' is not a number"
    k="${part%%=*}"
    v="${part#*=}"
    [[ "$v" =~ ^[0-9]+$ ]] ||
      die "${label}: '${v}' in '${part}' is not a number"
    if [[ "$k" == "default" ]]; then
      _def="$v"
    else
      _arr["$k"]="$v"
    fi
  done
}

source "$(dirname "$(readlink -f "$0")")/../common/bench_helper.sh"

#--------------------------------------------------------
#Systemsampler
#--------------------------------------------------------

SAMPLER_PROCESS_IDS=()

stop_samplers() {
  local pid
  for pid in "${SAMPLER_PROCESS_IDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  SAMPLER_PROCESS_IDS=()
}

cleanup() {
  stop_samplers
}

start_samplers() {
  local dir="$1"
  local mongopid="$2"

  mkdir -p "$dir"

  sar -u -r -b -w -q "$SAMPLE_INTERVAL" \
    >"$dir/sar.txt" 2>&1 &
  SAMPLER_PROCESS_IDS+=("$!")

  iostat -x -t "$SAMPLE_INTERVAL" \
    >"$dir/iostat.txt" 2>&1 &
  SAMPLER_PROCESS_IDS+=("$!")

  vmstat -t "$SAMPLE_INTERVAL" \
    >"$dir/vmstat.txt" 2>&1 &
  SAMPLER_PROCESS_IDS+=("$!")

  if ((mongopid > 0)); then
    pidstat -p "$mongopid" -u -r -d -h "$SAMPLE_INTERVAL" \
      >"$dir/pidstat_mongod.txt" 2>&1 &
    SAMPLER_PROCESS_IDS+=("$!")
  fi
}

trap cleanup EXIT INT TERM

#--------------------------------------------------------
#GUARDS
#--------------------------------------------------------

if [[ -f /etc/profile.d/ycsb.sh ]]; then
  source /etc/profile.d/ycsb.sh
else
  die "YCSB is not installed"
fi

[[ -x "${YCSB_HOME:-}/bin/ycsb.sh" ]] ||
  die "YCSB is not installed"

for tool in sar iostat vmstat pidstat; do
  command -v "$tool" >/dev/null 2>&1 ||
    die "${tool} not installed (package sysstat)"
done

case "$RESTORE_MODE" in
copy | mongorestore) ;;
*) die "--restore-mode must be copy|mongorestore" ;;
esac

if [[ "$RESTORE_MODE" == "mongorestore" ]]; then
  command -v mongorestore >/dev/null 2>&1 ||
    die "mongorestore not installed (package mongodb-database-tools)"
fi

mountpoint -q "$DATA_MOUNT" 2>/dev/null ||
  die "${DATA_MOUNT} is not mounted"

DATA_DEVICE="$(data_disk_device "$DATA_MOUNT")" ||
  die "cannot determine the device behind ${DATA_MOUNT}"

mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1 ||
  die "MongoDB is not reachable"

IFS=',' read -ra WORKLOADS_ <<<"$WORKLOADS"
for workload in "${WORKLOADS_[@]}"; do
  [[ -f "$YCSB_HOME/workloads/workload${workload}" ]] ||
    die "no YCSB workload file for '${workload}' in $YCSB_HOME/workloads"
done

OPS_SPEC="$OPERATIONS"
WU_SPEC="$WARMUP_OPS"
parse_counts "$OPS_SPEC" OPS_BY_WL OPERATIONS "--operations"
parse_counts "$WU_SPEC" WU_BY_WL WARMUP_OPS "--warmup-operations"

for k in "${!OPS_BY_WL[@]}" "${!WU_BY_WL[@]}"; do
  found=0
  for workload in "${WORKLOADS_[@]}"; do
    [[ "$workload" == "$k" ]] && {
      found=1
      break
    }
  done
  ((found)) || die "override for workload '${k}' but --workloads is '${WORKLOADS}'"
done

[[ -f "$STATE/mongodb_dataset" ]] ||
  die "no $STATE/mongodb_dataset - run load.sh first"

LOADED_RECORDS="$(awk -F= '/^records=/{print $2}' "$STATE/mongodb_dataset")"
LOAD_DIR="$(awk -F= '/^load_dir=/{print $2}' "$STATE/mongodb_dataset")"
if [[ -z "$DUMP_DIR" ]]; then
  DUMP_DIR="$(awk -F= '/^dump_dir=/{print $2}' "$STATE/mongodb_dataset")"
fi

if [[ -z "$RECORDS" ]]; then
  RECORDS="$LOADED_RECORDS"
fi

if [[ "$RECORDS" != "$LOADED_RECORDS" ]]; then
  die "--records ${RECORDS} but load.sh loaded ${LOADED_RECORDS} records."
fi

DATASET_ID="$(awk -F= '/^dataset_id=/{print $2}' "$STATE/mongodb_dataset")"
[[ -n "$DATASET_ID" ]] ||
  die "no dataset_id in $STATE/mongodb_dataset"

[[ -n "$DBPATH" ]] || DBPATH="${DATA_MOUNT}/mongodb"

PRISTINE_BYTES=""
PRISTINE_FILES=""
if [[ "$RESTORE_MODE" == "copy" ]]; then
  [[ -n "$PRISTINE_DIR" ]] || PRISTINE_DIR="${DATA_MOUNT}/pristine_${DATASET_ID}"

  if [[ ! -d "$PRISTINE_DIR" ]]; then
    die "no pristine data directory at ${PRISTINE_DIR}."
  fi

  [[ "$PRISTINE_DIR" != "$DBPATH" ]] ||
    die "--pristine-dir and --dbpath are the same directory (${DBPATH})"

  PRISTINE_BYTES="$(du -sb "$PRISTINE_DIR" | awk '{print $1}')"
  PRISTINE_FILES="$(find "$PRISTINE_DIR" -type f | wc -l)"
  ((PRISTINE_BYTES > 0 && PRISTINE_FILES > 0)) ||
    die "pristine directory ${PRISTINE_DIR} looks empty"
  log "Restore mode: copy from ${PRISTINE_DIR} (${PRISTINE_FILES} files, $((PRISTINE_BYTES / 1048576)) MB)"
else
  [[ -d "$DUMP_DIR/$DBNAME" ]] ||
    die "no dump of database '${DBNAME}' in ${DUMP_DIR} - run load.sh first"
  log "Restore mode: mongorestore from ${DUMP_DIR}"
fi

#--------------------------------------------------------
#Regime consistency
#--------------------------------------------------------

DATASET_MIB=""
if [[ -n "$PRISTINE_BYTES" ]]; then
  DATASET_MIB=$((PRISTINE_BYTES / 1048576))
elif [[ -f "${LOAD_DIR}/dataset_manifest.json" ]]; then
  DATASET_MIB="$(python3 -c'import json,sys; d=json.load(open(sys.argv[1])); print((d["storage_size_bytes"]+d["total_index_size_bytes"])//1048576)' \
    "${LOAD_DIR}/dataset_manifest.json" 2>/dev/null || true)"
fi

CACHE_MIB="$(mongo_num 'Math.round(db.serverStatus().wiredTiger.cache["maximum bytes configured"] / 1048576)')"
MEM_MIB=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))

if [[ -z "$DATASET_MIB" || -z "$CACHE_MIB" ]]; then
  log "WARNING: could not size the dataset or the cache - the regime label is UNVERIFIED"
else
  log "Regime check - dataset ${DATASET_MIB} MiB, cache ${CACHE_MIB} MiB, MemTotal ${MEM_MIB} MiB"
  case "$REGIME" in
  resident)
    ((DATASET_MIB <= CACHE_MIB)) ||
      die "--regime resident, but the dataset is ${DATASET_MIB} MiB against a ${CACHE_MIB} MiB cache,
      so it cannot be resident."
    ;;
  exceeding)
    ((DATASET_MIB > MEM_MIB)) ||
      die "--regime exceeding, but the dataset is ${DATASET_MIB} MiB of RAM,
          so it does not exceed memory."
    ;;
  esac
fi
#--------------------------------------------------------
#Helper functions
#--------------------------------------------------------

enforce_write_to_storage() {
  before="$(mongo_num 'db.serverStatus().wiredTiger.cache["tracked dirty bytes in the cache"]')"
  mongosh --quiet --eval 'db.adminCommand({fsync:1})' >/dev/null 2>&1 || true
  sync
  sleep "$DRAIN_SECONDS"
  after="$(mongo_num 'db.serverStatus().wiredTiger.cache["tracked dirty bytes in the cache"]')"
  before="${before:-0}"
  after="${after:-0}"
  log "Drained ${DRAIN_SECONDS}s: unwritten data before: $((before / 1048576)) MB -> After: $((after / 1048576)) MB"
}

reset_mongo_state() {
  systemctl restart mongod
  wait_for_mongod
  sync
  echo 3 >/proc/sys/vm/drop_caches
  sleep 5
}

restore_dataset() {
  local run_dir="$1" rep="$2"
  local start count bytes files

  start="$(date -u +%s)"
  if [[ "$RESTORE_MODE" == "copy" ]]; then
    systemctl stop mongod ||
      die "could not stop mongod before the copy"

    rm -rf "${DBPATH:?}" ||
      die "could not remove ${DBPATH}"
    cp -a "$PRISTINE_DIR" "$DBPATH" ||
      die "copy from ${PRISTINE_DIR} to ${DBPATH} failed (disk full?)"
    chown -R mongodb:mongodb "$DBPATH" ||
      die "could not chown ${DBPATH}"

    sync

    bytes="$(du -sb "$DBPATH" | awk '{print $1}')"
    files="$(find "$DBPATH" -type f | wc -l)"
    [[ "$bytes" == "$PRISTINE_BYTES" ]] ||
      die "restored ${DBPATH} holds ${bytes} bytes, pristine holds ${PRISTINE_BYTES}"
    [[ "$files" == "$PRISTINE_FILES" ]] ||
      die "restored ${DBPATH} holds ${files} files, pristine holds ${PRISTINE_FILES}"

    systemctl start mongod ||
      die "mongod did not start after the copy - ${PRISTINE_DIR} may have been taken from running mongod"
    wait_for_mongod
  else
    mongorestore --quiet --drop --nsInclude "${DBNAME}.*" "$DUMP_DIR" \
      >"$run_dir/restore.stdout" 2>"$run_dir/restore.stderr" ||
      die "mongorestore failed, see $run_dir/restore.stderr"
  fi

  RESTORE_SECONDS=$(($(date -u +%s) - start))

  if ((rep == 1)); then
    VERIFY_METHOD="countDocuments"
    count="$(mongo_num 'db.usertable.countDocuments({})' "$DBNAME")"
  else
    VERIFY_METHOD="estimatedDocumentCount"
    count="$(mongo_num 'db.usertable.estimatedDocumentCount()' "$DBNAME")"
  fi
  count="${count:-0}"
  if ((count != RECORDS)); then
    die "after the restore: '${DBNAME}.usertable' holds ${count} documents, expected ${RECORDS} (${VERIFY_METHOD})"
  fi
  log "Restored ${count} documents in ${RESTORE_SECONDS}s (${RESTORE_MODE}, verified by ${VERIFY_METHOD})"

}

ycsb_run() {
  local workload="$1"
  local operation="$2"
  local prefix="$3"
  local recordcount="$4"
  local args=(
    run mongodb -s
    -P "$YCSB_HOME/workloads/workload${workload}"
    -p recordcount="$recordcount"
    -p operationcount="$operation"
    -p threadcount="$THREADS"
    -p mongodb.url="mongodb://127.0.0.1:27017/${DBNAME}?w=1"
    -p measurementtype=hdrhistogram
    -p hdrhistogram.percentiles="50,95,99"
  )
  {
    printf 'taskset -c %q %q' \
      "$YCSB_CORES" \
      "$YCSB_HOME/bin/ycsb.sh"
    printf ' %q' "${args[@]}"
    printf '\n'
  } >"${prefix}.command"

  taskset -c "$YCSB_CORES" \
    "$YCSB_HOME/bin/ycsb.sh" \
    "${args[@]}" \
    >"${prefix}.stdout" 2>"${prefix}.stderr"
}

check_exeeding_regime() {
  local summary="$1" workload="$2" verdict
  verdict="$(python3 "$SCRIPT_DIR/check_regime.py" "$summary" "$MIN_IOWAIT_PCT" "$MIN_READ_IOPS")" ||
    verdict="unknown: the os_summary could not be read"

  case "$verdict" in
  ok:*)
    log "Exceeding regime confirmed for workload ${workload}: ${verdict#ok: }"
    ;;
  *)
    log "WARNING: workload ${workload} may not be in the exceeding regime - ${verdict}"
    ;;
  esac
}

#--------------------------------------------------------
#Benchmark
#--------------------------------------------------------

log "Benchmark start - config=${CONFIG} regime=${REGIME} round=${ROUND} workloads=${WORKLOADS}"
log "${RECORDS} records, ${THREADS} threads, ${REPS} reps"
log " operations: default ${OPERATIONS}$(
  for k in "${!OPS_BY_WL[@]}"; do printf ', %s=%s' "$k" "${OPS_BY_WL[$k]}"; done
)"
log " warm-up:    default ${WARMUP_OPS}$(
  for k in "${!WU_BY_WL[@]}"; do printf ', %s=%s' "$k" "${WU_BY_WL[$k]}"; done
)"
log "Dataset restored from ${DUMP_DIR} before every run; data disk ${DATA_DEVICE}"
log "Mode: $([[ "$COLD" -eq 1 ]] && echo 'Cold (restart + drop catches per repetition)' || echo 'Warm (no reset)')"
log "Writeback drain: $([[ "$DO_DRAIN" -eq 1 ]] && echo "${DRAIN_SECONDS}s after each workload" || echo 'DISABLED')"

TOTAL=$((${#WORKLOADS_[@]} * REPS))
DONE=0
FAILED=0

for ((rep = 1; rep <= REPS; rep++)); do
  for workload in "${WORKLOADS_[@]}"; do
    TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
    RUN_DIR="${ROUND_DIR}/${TIMESTAMP}__mongodb__${CONFIG}__${REGIME}__ycsb-${workload}__r$(printf '%02d' "$rep")"

    if [[ -e "$RUN_DIR" ]]; then
      die "Round already exist"
    fi

    DONE=$((DONE + 1))
    log "[${DONE}/${TOTAL}] workload ${workload}, repetition ${rep}"

    mkdir -p "$RUN_DIR/os_metrics" "$RUN_DIR/db_metrics"

    restore_dataset "$RUN_DIR" "$rep"

    if [[ "$COLD" -eq 1 ]]; then
      log "Cold run, resetting state"
      reset_mongo_state
    fi

    mongosh --quiet --eval 'JSON.stringify(db.serverStatus())' \
      >"$RUN_DIR/db_metrics/serverstatus_before.json" 2>/dev/null || true

    RUN_OPS="${OPS_BY_WL[$workload]:-$OPERATIONS}"
    RUN_WU="${WU_BY_WL[$workload]:-$WARMUP_OPS}"

    if ((RUN_WU > 0)); then
      log "Warm-up with ${RUN_WU} operations"
      warm_up_start="$(date -u +%s)"
      ycsb_run "$workload" "$RUN_WU" "$RUN_DIR/ycsb_warmup" "$RECORDS" ||
        log "Warm up reported an error, check logs after."
      log " Warm-up took $(($(date -u +%s) - warm_up_start))s"
    fi

    WARMUP_INSERTS=0
    if [[ -f "$RUN_DIR/ycsb_warmup.stdout" ]]; then
      WARMUP_INSERTS="$(
        awk -F', *' '$1 == "[INSERT]" && $2 == "Return=OK" { print $3 }' \
          "$RUN_DIR/ycsb_warmup.stdout"
      )"
      WARMUP_INSERTS="${WARMUP_INSERTS:-0}"
    fi
    MEASURED_RECORDCOUNT=$((RECORDS + WARMUP_INSERTS))

    mongosh --quiet --eval 'JSON.stringify(db.serverStatus())' \
      >"$RUN_DIR/db_metrics/serverstatus_after_warmup.json" 2>/dev/null || true

    MONGO_PROCESS_ID="$(largest_process_in_unit mongod.service)" ||
      die "cannot find the mongod process in mongod.service"
    assert_process_is_working "$MONGO_PROCESS_ID" "mongod"

    log "Executing and measuring ${RUN_OPS} operations"
    start_samplers "$RUN_DIR/os_metrics" "$MONGO_PROCESS_ID"
    MEASUREMENT_START="$(date -u +%s)"

    if ycsb_run "$workload" "$RUN_OPS" "$RUN_DIR/ycsb" "$MEASURED_RECORDCOUNT"; then
      OK=True
    else
      OK=False
      log "Error during measuring, check stderr log after"
    fi
    MEASUREMENT_END=$(($(date -u +%s) - MEASUREMENT_START))
    stop_samplers

    summarise_run_os_metrics "$RUN_DIR" "$DATA_DEVICE"

    if [[ "$REGIME" == "exceeding" && "$rep" -eq 1 ]]; then
      check_exeeding_regime "$RUN_DIR/os_summary.json" "$workload"
    fi

    mongosh --quiet --eval 'JSON.stringify(db.serverStatus())' \
      >"$RUN_DIR/db_metrics/serverstatus_after.json" 2>/dev/null || true
    cp -a /etc/mongod.conf "$RUN_DIR/db_metrics/mongod.conf" 2>/dev/null || true

    if [[ "$DO_DRAIN" -eq 1 ]]; then
      enforce_write_to_storage
    fi

    CACHE_FILL_MB="$(python3 "$SCRIPT_DIR/cache_fill.py" "$RUN_DIR/db_metrics")" || CACHE_FILL_MB=""

    DISK_READ_MB="$(python3 -c \
      'import json,sys; print(int(json.load(open(sys.argv[1])).get("disk_read_mib") or 0))' \
      "$RUN_DIR/os_summary.json" 2>/dev/null)" || DISK_READ_MB=""

    if [[ "$REGIME" != "resident" ]]; then
      log "Cache fill during measurement: ${CACHE_FILL_MB:-?} MB into cache, ${DISK_READ_MB:-?} MB from disk (expected in the ${REGIME} regime)"
    elif [[ -z "$DISK_READ_MB" || -z "${DATASET_MIB:-}" ]] || ((DATASET_MIB == 0)); then
      log "Warm-up verdict: UNKNOWN (os_summary or dataset size missing)"
    fi
    THROUGHPUT="$(
      awk -F', ' '/^\[OVERALL\], Throughput/ { print $3; exit}' \
        "$RUN_DIR/ycsb.stdout" 2>/dev/null
    )"
    FAILED_OPS="$(
      awk -F', *' \
        '/^\[[A-Z-]*-FAILED\], Operations/ { s += $3 }
      END { print s + 0 }' \
        "$RUN_DIR/ycsb.stdout" 2>/dev/null
    )"
    NOTFOUND="$(
      awk -F', *' \
        '/Return=NOT_FOUND/ { s += $3 }
      END { print s + 0 }' \
        "$RUN_DIR/ycsb.stdout" 2>/dev/null
    )"
    ERRORS="$(
      awk -F', *' \
        '/Return=ERROR/ { s += $3 }
      END { print s + 0 }' \
        "$RUN_DIR/ycsb.stdout" 2>/dev/null
    )"
    OK_OPS="$(
      awk -F', *' \
        '/^\[(READ|UPDATE|INSERT|SCAN|READ-MODIFY-WRITE)\], Operations/ {
          s += $3
        }
        END { print s + 0 }' \
        "$RUN_DIR/ycsb.stdout" 2>/dev/null
    )"
    if ((FAILED_OPS > 0 || NOTFOUND > 0 || ERRORS > 0 || OK_OPS == 0)); then
      OK=False

      log "Run failed, check stderr for more infos"
    else
      log "  done in ${MEASUREMENT_END}s, ${OK_OPS} ops, throughput ${THROUGHPUT} ops/sec"
    fi

    if [[ "$OK" == "False" ]]; then
      FAILED=$((FAILED + 1))
    fi

    python3 "$SCRIPT_DIR/write_mongodb_manifest.py" \
      "$RUN_DIR/manifest.json" \
      "$(basename "$RUN_DIR")" \
      "$TIMESTAMP" \
      "$ROUND" \
      "$CONFIG" \
      "$REGIME" \
      "${workload}" \
      "${rep}" \
      "${OK}" \
      "${OK_OPS}" \
      "${FAILED_OPS}" \
      "${NOTFOUND}" \
      "${ERRORS}" \
      "${THROUGHPUT:-0}" \
      "$RUN_DIR/os_summary.json" \
      "${DATA_DEVICE}" \
      "${LOAD_DIR}/dataset_manifest.json" \
      "${RECORDS}" \
      "${RUN_OPS}" \
      "${RUN_WU}" \
      "${OPS_SPEC}" \
      "${WU_SPEC}" \
      "${WARMUP_INSERTS}" \
      "${MEASURED_RECORDCOUNT}" \
      "${THREADS}" \
      "$([[ "$COLD" -eq 1 ]] && echo True || echo False)" \
      "${RESTORE_SECONDS}" \
      "${RESTORE_MODE}" \
      "${VERIFY_METHOD}" \
      "${PRISTINE_DIR:-$DUMP_DIR}" \
    "${DUMP_DIR}" \
      "$(
        [[ "$DO_DRAIN" -eq 1 ]] &&
          echo "$DRAIN_SECONDS" ||
          echo 0
      )" \
      "${YCSB_CORES}" \
      "${SAMPLE_INTERVAL}" \
      "${MEASUREMENT_END}"
  done
done

log "Benchmark done"
