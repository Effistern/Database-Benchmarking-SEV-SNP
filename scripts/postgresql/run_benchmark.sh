#!/usr/bin/env bash
set -euo pipefail

#--------------------------------------------------------------------------------
# Configuration
#--------------------------------------------------------------------------------

CONFIG=""
ROUND=""
REGIME=""
WORKLOAD=""
THREADS=2
DBUSER="postgres"
DBPASS="postgres"
RAMPUP=1
DURATION=3
REPS=2
SAMPLE_INTERVAL=1
STATE="/var/lib/db-benchmark"

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
HELPERS="$(cd "${HERE}/.." && pwd)/common/bench_helpers.sh"

#--------------------------------------------------------------------------------
# Argument parsing
#--------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
  --config)
    CONFIG="${2:?ERROR: --config required a value}"
    shift 2
    ;;
  --round)
    ROUND="${2:?ERROR: --round required a value}"
    shift 2
    ;;
  --regime)
    REGIME="${2:?ERROR: --regime required a value}"
    shift 2
    ;;
  --workload)
    WORKLOAD="${2:?ERROR: --workload required a value}"
    shift 2
    ;;
  --threads)
    THREADS="${2:?ERROR: --threads required a value}"
    shift 2
    ;;
  --dbuser | --user)
    DBUSER="${2:?ERROR: --dbuser required a value}"
    shift 2
    ;;
  --dbpass | --pass)
    DBPASS="${2:?ERROR: --dbpass required a value}"
    shift 2
    ;;
  --rampup)
    RAMPUP="${2:?ERROR: --rampup required a value}"
    shift 2
    ;;
  --duration)
    DURATION="${2:?ERROR: --duration required a value}"
    shift 2
    ;;
  --repetitions)
    REPS="${2:?ERROR: --repetitions required a value}"
    shift 2
    ;;
  --sample-interval)
    SAMPLE_INTERVAL="${2:?ERROR: --sample-interval required a value}"
    shift 2
    ;;
  --state)
    STATE="${2:?ERROR: --state required a value}"
    shift 2
    ;;
  *)
    echo "ERROR: Unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

case "$CONFIG" in none | sev | snp) ;;
"")
  echo "ERROR: --config required" >&2
  exit 2
  ;;
*)
  echo "ERROR: --config must be none|sev|snp" >&2
  exit 2
  ;;
esac

if ! [[ -n "$ROUND" ]]; then
  echo "ERROR: --round required" >&2
  exit 2
fi

#--------------------------------------------------------------------------------
# Dataset State
#--------------------------------------------------------------------------------

DATASET_FILE="${STATE}/postgres_dataset"
[[ -f "$DATASET_FILE" ]] || {
  echo "ERROR: no active dataset at ${DATASET_FILE}" >&2
  exit 2
}

ds() { awk -F= -v k="$1" '$1==k{print $2}' "$DATASET_FILE"; }
DATASET_ID="$(ds dataset_id)"
DS_WORKLOAD="$(ds workload)"
DS_REGIME="$(ds regime)"
DS_ROWS="$(ds rows)"
DS_ROWS_TABLE="$(ds rows_table)"
DS_PRISTINE_BYTES="$(ds pristine_bytes)"

[[ -n "$DATASET_ID" ]] || {
  echo "ERROR: no dataset_id in ${DATASET_FILE}" >&2
  exit 2
}

REGIME="$DS_REGIME"
WORKLOAD="$DS_WORKLOAD"
SCALE_FACTOR="${SCALE_FACTOR:-1}"

case "$WORKLOAD" in
tprocc | tpcc)
  WORKLOAD="tprocc"
  TARGET_DB="tpcc"
  ;;
tproch | tpch)
  WORKLOAD="tproch"
  TARGET_DB="tpch"
  ;;
esac

ROUND_DIR="./raw_results/${ROUND}"
LOG="${ROUND_DIR}/${CONFIG}_benchmark.log"
FAILED=0
mkdir -p "$ROUND_DIR"

#--------------------------------------------------------------------------------
# Helper functions
#--------------------------------------------------------------------------------

pg_query() {
  local db="$1"
  local query="$2"

  PGPASSWORD="$DBPASS" psql -h localhost \
    -U "$DBUSER" -d "$db" -t -A -c "$query" 2>/dev/null ||
    echo ""
}

log() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2 || true
}

die() {
  log "FATAL: $*"
  exit 1
}

wait_for_postgres() {
  for _ in $(seq 1 30); do
    PGPASSWORD="$DBPASS" psql -h localhost -U "$DBUSER" -d postgres -c "SELECT 1;" >/dev/null 2>&1 && return 0
    sleep 2
  done
  die "PostgreSQL did not come back after restart."
}

restore_cluster() {
  log "Restoring ${DATASET_ID} from its pristine copy."
  "${HERE}/restore.sh" >>"$LOG" 2>&1 || die "restore.sh failed - see ${LOG} and /var/log/postgres_restore.log"
  wait_for_postgres
}

verify_actual_scale() {
  local workload="$1"
  local target_db="$2"
  local actual_count=0

  if [[ "$workload" == "tprocc" ]]; then
    actual_count=$(pg_query "$target_db" "SELECT count(*) FROM warehouse;" | tr -d '[:space:]')
  else
    local cust_count=$(pg_query "$target_db" "SELECT count(*) FROM customer;" | tr -d '[:space:]')
    if [[ -n "$cust_count" && "$cust_count" -gt 0 ]]; then
      actual_count=$((cust_count / 150000))
    fi
  fi

  [[ -n "$actual_count" && "$actual_count" -gt 0 ]] || die "Restore valdation failed."
  echo "$actual_count"
}

#--------------------------------------------------------------------------------
# Background Metric Samplers
#--------------------------------------------------------------------------------

SAMPLER_PIDS=()
stop_samplers() {
  for p in "${SAMPLER_PIDS[@]:-}"; do
    [[ -n "${p:-}" ]] && kill "$p" 2>/dev/null || true
  done
  SAMPLER_PIDS=()
}

trap "stop_samplers" EXIT INT TERM

start_samplers() {
  local dir="$1" pgpid="$2"
  mkdir -p "$dir"
  sar -u -r -b -w -q "$SAMPLE_INTERVAL" >"$dir/sar.txt" 2>&1 &
  SAMPLER_PIDS+=($!)
  iostat -x -t "$SAMPLE_INTERVAL" >"$dir/iostat.txt" 2>&1 &
  SAMPLER_PIDS+=($!)
  vmstat -t "$SAMPLE_INTERVAL" >"$dir/vmstat.txt" 2>&1 &
  SAMPLER_PIDS+=($!)
  if [[ "${pgpid:-0}" -gt 0 ]]; then
    pidstat -G postgres -u -r -d -h "$SAMPLE_INTERVAL" >"$dir/pidstat_postgres.txt" 2>&1 &
    SAMPLER_PIDS+=($!)
  fi
}

PG_MAJOR="$(ls -1 /etc/postgresql 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1 || true)"
POSTGRES_UNIT="postgresql@${PG_MAJOR:-16}-main"

postgres_pid() {
  systemctl show "$POSTGRES_UNIT" -p MainPID --value 2>/dev/null || echo 0
}

LOAD1="$(awk '{print $1; exit}' /proc/loadav 2>/dev/null || echo "0.00")"

DATA_DEVICE="sdb"
if [[ -f "$HELPERS" ]]; then
  source "$HELPERS"
  DATA_DEVICE="$(data_disk_device "/mnt/dbdata" 2>/dev/null || echo sdb)"
  HAVE_HELPERS=1
else
  HAVE_HELPERS=0
fi

#--------------------------------------------------------------------------------
# TCL Generator
#--------------------------------------------------------------------------------

generate_hammerdb_tcl() {
  local workload="$1"
  local tcl_file="$2"
  local target_db="$3"

  if [[ "$workload" == "tprocc" ]]; then
    cat <<EOF >"$tcl_file"
dbset db pg
dbset bm TPROC-C

diset connection pg_host localhost
diset connection pg_port 5432

diset tpcc pg_dbase ${target_db}
diset tpcc pg_user ${DBUSER}
diset tpcc pg_pass ${DBPASS}

diset tpcc pg_storedprocs true
diset tpcc pg_driver timed
diset tpcc pg_rampup ${RAMPUP}
diset tpcc pg_duration ${DURATION}
diset tpcc pg_allwarehouse true
diset tpcc pg_timeprofile true

vuset vu ${THREADS}
vuset logtotemp true
vuset unique true
    
loadscript
vurun
EOF
  else
    cat <<EOF >"$tcl_file"
dbset db pg
dbset bm TPROC-H

diset connection pg_host localhost
diset connection pg_port 5432

diset tpch pg_tpch_dbase ${target_db}
diset tpch pg_tpch_user ${DBUSER}
diset tpch pg_tpch_pass ${DBPASS}

diset tpch pg_num_tpch_threads ${THREADS}
diset tpch pg_scale_fact ${SCALE_FACTOR}

vuset vu ${THREADS}
vuset logtotemp true
vuset unique true
    
loadscript
vurun
EOF
  fi
}

#--------------------------------------------------------------------------------
# Main Loop
#--------------------------------------------------------------------------------

run_workload() {
  local workload="$1"
  local rep="$2"
  local wl_upper="$(echo "$workload)" | tr '[:lower:]' '[:upper:]')"

  TS="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_DIR="$(mkdir -p "${ROUND_DIR}" && cd "${ROUND_DIR}" && pwd)/${TS}__postgres__${CONFIG}__${workload}_${REGIME}__r$(printf '%02d' "$rep")"

  log "Running ${wl_upper} (${REGIME}, ${DATASET_ID}) - repetition ${rep}/${REPS}"

  restore_cluster

  ACTUAL_SCALE="$(verify_actual_scale "$workload" "$TARGET_DB")"
  mkdir -p "$RUN_DIR" "$RUN_DIR/os_metrics" "$RUN_DIR/db_metrics"

  if [[ "$workload" == "tproch" && "$REGIME" == "resident" ]]; then
    for t in lineitem orders partsup customer part suppliert nation region; do
      pg_query "$TARGET_DB" "SELECT count(*) FROM ${t};" >/dev/null 2>&1 || true
    done
  fi

  PGPID="$(postgres_pid)"
  pg_query "$TARGET_DB" "SELECT * FROM pg_stat_database WHERE datname='${TARGET_DB};" >"$RUN_DIR/db_metrics/pg_stat_db_before.txt"

  TCL_SCRIPT="/tmp/run_${workload}_r${rep}.tcl"
  generate_hammerdb_tcl "$workload" "$TCL_SCRIPT" "$TARGET_DB"

  start_samplers "$RUN_DIR/os_metrics" "$PGPID"
  MSTART="$(date -u +%s)"

  local ok=True

  if (cd "/opt/HammerDB-6.0" && TMP="$RUN_DIR" TMPDIR="$RUN_DIR" \
    taskset -c 1,3 ./hammerdbcli auto "$TCL_SCRIPT" | tee "$RUN_DIR/hammerdb.stdout" 2>&1); then
    ok=True
  else
    ok=False
    FAILED=$((FAILED + 1))
    log "ERROR: ${wl_upper} run failed."
  fi

  ELAPSED=$(($(date -u +%s) - MSTART))
  stop_samplers

  pg_query "$TARGET_DB" "SELECT * FROM pg_stat_database WHERE datname='${TARGET_DB}';" >"$RUN_DIR/db_metrics/pg_stat_dbafter.txt"
  if [[ "$HAVE_HELPERS" -eq 1 ]]; then
    summarise_run_os_metrics "$RUN_DIR" "$DATA_DEVICE"
  else
    echo '{}' >"$RUN_DIR/os_summary.json"
  fi
  NOPM=0
  TPM=0
  GEOMEAN=0
  if [[ "$workload" == "tprocc" ]]; then
    NOPM="$(awk '/TEST RESULT/ {for(i=1;i<=NF;i++) if($i=="NOPM") print $(i-1)}' "$RUN_DIR/hammerdb.stdout" | tail -n 1)"
    TPM="$(awk '/TEST RESULT/ {for(i=1;i<=NF;i++) if($i=="TPM") print $(i-2)}' "$RUN_DIR/hammerdb.stdout" | tail -n 1)"
    log "done in ${ELAPSED}s | NOPM: ${NOPM} | TPM: ${TPM}"
  else
    GEOMEAN="$(awk '/[Gg]eometric [Mm]ean/ {print $NF}' "$RUN_DIR/hammerdb.stdout" | tail -n 1)"
    GEOMEAN="${GEOMEAN:-0}"
    log "done in ${ELAPSED}s | Geometric Mean Query Time: ${GEOMEAN}s"

    awk '
            match($0, /query [0-9]+ completed in [0-9.]+ seconds/) {
            s = substr($0, RSTART, RLENGTH)
            split(s, a, " ")
            printf "%s\t%s\n", a[2], a[5]
        }' "$RUN_DIR/hammerdb.stdout" | sort -n -k1,1 >"$RUN_DIR/db_metrics/per_query_seconds.tsv"
    QN="$(wc -l <"$RUN_DIR/db_metrics/per_query_seconds.tsv")"
    log "per-query times captured: ${QN}/22"
  fi
  local SCRIPT_DIR
  SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
  python3 "$SCRIPT_DIR/write_run_benchmark.py" \
    "$RUN_DIR/manifest.json" \
    "${TS}" "${ROUND}" "${CONFIG:-none}" "${workload}" "${REGIME}" "${rep}" "${ok}" \
    "${NOPM}" "${TPM}" "${GEOMEAN}" "${ACTUAL_SCALE}" \
    "${THREADS}" "${RAMPUP}" "${DURATION}" "${SAMPLE_INTERVAL}" \
    "${ELAPSED}" "${LOAD1}" \
    "${DATASET_ID}" "${DS_ROWS}" "${DS_ROWS_TABLE}" "${DS_PRISTINE_BYTES}" \
    "${DATA_DEVICE}" "${RUN_DIR}/os_summary.json" "${POSTGRES_UNIT}"
  rm -f "$TCL_SCRIPT"
}

#--------------------------------------------------------------------------------
# Main Orchestrator Loop (Seq. TC1 -> TH1 -> TC2 -> TH2 -> ...)
#--------------------------------------------------------------------------------

log "PostgreSQL benchmark - config=${CONFIG} round=${ROUND}"
log "(workload=${WORKLOAD} regime=${REGIME})"
log "data device: ${DATA_DEVICE} postgres unit: ${POSTGRES_UNIT}"

for rep in $(seq 1 "$REPS"); do
  run_workload "$WORKLOAD" "$rep"
done

log "Finished - ${REPS} repetition(s), ${FAILED} failure(s)"
[[ "$FAILED" -eq 0 ]] || exit 1
