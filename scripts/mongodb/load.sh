#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/lib.sh"

#--------------------------------------------------------
#Configuration
#--------------------------------------------------------

CONFIG="";
RECORDS=5000000;
FIELDLEN=100;
THREADS=2;
YCSB_CORES="1,3";
DBNAME="ycsb";
SEED=20262027;
OUT_ROOT="./raw_results";
DUMP_ROOT="/mnt/dbdata/mongodb_dump";
STATE="/var/lib/db-benchmark";
DROP=0;

#--------------------------------------------------------
#Argument parsing
#--------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)             CONFIG="$(arg_value "$@")";      shift 2 ;;
    --records)            RECORDS="$(arg_value "$@")";     shift 2 ;;
    --fieldlength)        FIELDLEN="$(arg_value "$@")";    shift 2 ;;
    --threads)            THREADS="$(arg_value "$@")";     shift 2 ;;
    --ycsb-cores)         YCSB_CORES="$(arg_value "$@")";  shift 2 ;;
    --db)                 DBNAME="$(arg_value "$@")";      shift 2 ;;
    --seed)               SEED="$(arg_value "$@")";        shift 2 ;;
    --out)                OUT_ROOT="$(arg_value "$@")";    shift 2 ;;
    --dump-dir)           DUMP_ROOT="$(arg_value "$@")";   shift 2 ;;
    --drop)               DROP=$(arg_flag);                shift   ;;
    *)                    echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

validate_config "$CONFIG"

#---------------------------------------------------------
#Run identity
#---------------------------------------------------------

TS="$(date -u +%Y%m%dT%H%M%SZ)"
DATASET_ID="ycsb-r${RECORDS}-f${FIELDLEN}-s${SEED}"
CAMPAIGN="${OUT_ROOT}/${TS}__mongodb-load__${CONFIG}__${DATASET_ID}"
DUMP_DIR="${DUMP_ROOT}/${DATASET_ID}"

mkdir -p "$CAMPAIGN"
BENCH_LOG="${CAMPAIGN}/load.log"
lib_init

#---------------------------------------------------------
#Guards
#---------------------------------------------------------

source_ycsb_profile
require_cmd mongosh mongodump
mongod_reachable ||
  die "MongoDB is not reachable"

#---------------------------------------------------------
#Dropping existing DB data
#---------------------------------------------------------

log "Checking Datatbase"

EXISTING="$(mongo_num 'db.usertable.countDocuments({})' "$DBNAME")"
EXISTING="${EXISTING:-0}"
if (( EXISTING > 0 )); then
  if (( ! DROP )); then
    die "Datatbase already holds data."
  fi
  log "Dropping existing database"
  run mongosh --quiet "$DBNAME" --eval 'db.dropDatabase()'
fi

#--------------------------------------------------------
#Loading Data
#--------------------------------------------------------

YCSB_ARGS=(
  load mongodb -s
  -P "$YCSB_HOME/workloads/workloada"
  -p recordcount="$RECORDS"
  -p fieldlength="$FIELDLEN"
  -p insertstart=0
  -p threadcount="$THREADS"
  -p mongodb.url="mongodb://127.0.0.1:27017/${DBNAME}?w=1"
  -p mongodb.batchsize=1
  -p randomseed="$SEED"
)

printf 'taskset -c %q %q' \
  "$YCSB_CORES" \
  "$YCSB_HOME/bin/ycsb.sh" \
  > "$CAMPAIGN/command.txt"
printf ' %q' "${YCSB_ARGS[@]}" >> "$CAMPAIGN/command.txt"
printf '\n' >> "$CAMPAIGN/command.txt"

log "Loading data into database"
START="$(date -u +%s)"
taskset -c "$YCSB_CORES" \
  "$YCSB_HOME/bin/ycsb.sh" \
  "${YCSB_ARGS[@]}" \
  > "$CAMPAIGN/ycsb_load.stdout" \
  2> "$CAMPAIGN/ycsb_load.stderr" ||
    die "YCSB load failed, check $CAMPAIGN/ycsb_load.stderr"
  ELAPSED=$(( $(date -u +%s) - START ))
  log "load finished in ${ELAPSED}s"

#--------------------------------------------------------
#Verifying loaded data
#--------------------------------------------------------

COUNT="$(mongo_num 'db.usertable.countDocuments({})' "$DBNAME")"
COUNT="${COUNT:-0}"
if (( COUNT != RECORDS )); then
  die "Document count ${COUNT} does not match expected count ${RECORDS}"
fi
log "Verfied document count: ${COUNT}"

#--------------------------------------------------------
#Recording what the load produced
#--------------------------------------------------------

COLLSTATS="$CAMPAIGN/collstats.json"
mongosh --quiet "$DBNAME" --eval \
  'print(EJSON.stringify(db.usertable.aggregate([{ $collStats: { storageStats: {} } }]).toArray()))' \
  > "$COLLSTATS" 2> "$CAMPAIGN/collstats.err" ||
    die "collecting \$collstats failed, see $CAMPAIGN/collstats.err"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
SIZE_MB="$(python3 "$SCRIPT_DIR/collstats.py" "$COLLSTATS" "$CAMPAIGN/dataset_manifest.json" \
  "$DATASET_ID" "$RECORDS" "$FIELDLEN" "$SEED" "$COUNT" "$ELAPSED"
)" || die "the \$collStats output in ${COLLSTATS} is not usabel"

log "Realised size: ${SIZE_MB} MB of documents - details in $CAMPAIGN/dataset_manifest.json"

CACHE_MB="$(mongo_num \
  'Math.round(db.serverStatus().wiredTiger.cache["maximum bytes configured"] / 1048576)')"
CACHE_MB="${CACHE_MB:-0}"

if (( SIZE_MB > CACHE_MB )); then
  log "DB doesnt fully fit into memory. Reads would hit disk"
fi

#--------------------------------------------------------
#Reference dump
#--------------------------------------------------------

log "Dumping the loaded dataset to ${DUMP_DIR}"
mkdir -p "$DUMP_DIR"
mongodump --quiet --db "$DBNAME" --out "$DUMP_DIR" \
  2> "$CAMPAIGN/mongodump.stderr" ||
    die "mongodump failed, see $CAMPAIGN/mongodump.stderr"

mkdir -p "$STATE"
{
  printf 'dataset_id=%s\n' "$DATASET_ID"
  printf 'database=%s\n' "$DBNAME"
  printf 'records=%s\n' "$COUNT"
  printf 'dump_dir=%s\n' "$DUMP_DIR"
  printf 'load_dir=%s\n' "$(cd "$CAMPAIGN" && pwd)"
  printf 'loaded_utc=%s\n' "$TS"
} > "$STATE/mongodb_dataset"
log "recorded ${STATE}/mongodb_dataset"

log "Loading dataset done"