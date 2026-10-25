#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------
# Variables
# -----------------------------------------------------------------

PRISTINE_DIR=""
MAKE_PRISTINE=0
STATE="/var/lib/db-benchmark"
LOG="/var/log/neo4j_restore.log"
DATABASE="neo4j"

# -----------------------------------------------------------------
# Parsing
# -----------------------------------------------------------------

while (($#)); do
  case "$1" in
  --make-pristine)
    MAKE_PRISTINE=1
    shift
    ;;
  --pristine-dir)
    PRISTINE_DIR="${2:?Missing value for --prisitine-dir}"
    shift 2
    ;;
  *)
    echo "ERROR: Unknow argument: $1" >&2
    exit 2
    ;;
  esac
done

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

mkdir -p "$STATE"
touch "$LOG"

log "Checking if datasets have been created: "

# -----------------------------------------------------------------
# Guards
# -----------------------------------------------------------------

if [[ ! -f "$STATE/neo4j_dataset" ]]; then
  die "No dataset state found"
fi

DATASET_ID="$(awk -F= '/^dataset_id=/{print $2}' "$STATE/neo4j_dataset")"
if [[ -z "$DATASET_ID" ]]; then
  die "No dataset id in load state."
fi

DATA_DIR="$(awk -F= '/^data_dir=/{print $2}' "$STATE/neo4j_setup" 2>/dev/null || true)"
if [[ -z "$DATA_DIR" ]]; then
  DATA_DIR="/mnt/dbdata/neo4j/data"
fi

JAVA_HOME_DIR="$(awk -F = '/^java_home=/{print $2; exit}' "$STATE/neo4j_setup" 2>/dev/null || true)"
if [[ -x "$JAVA_HOME_DIR/bin/java" ]]; then
  NEO4J_ENV=(env "JAVA_HOME=$JAVA_HOME_DIR" "PATH=$JAVA_HOME_DIR/bin:$PATH")
else
  NEO4J_ENV=(env)
fi

STORE_DB="${DATA_DIR}/databases/${DATABASE}"
TX_ROOT="$(dirname "$DATA_DIR")/transactions"
STORE_TX="${TX_ROOT}/${DATABASE}"

if [[ -z "$PRISTINE_DIR" ]]; then
  PRISTINE_DIR="$(dirname "$DATA_DIR")/pristine_${DATASET_ID}"
fi

# -----------------------------------------------------------------
# Make copy, Restory copy
# -----------------------------------------------------------------

stop_neo4j() {
  systemctl stop neo4j
  for _ in $(seq 1 30); do
    systemctl is-active --quiet neo4j || break
    sleep 1
  done
  if systemctl is-active --quiet neo4j; then
    die "Neo4j did not stop"
  fi
}

if [[ "$MAKE_PRISTINE" -eq 1 ]]; then
  log "Creating pristine copy"
  if [[ ! -d "$STORE_DB" ]]; then
    die "No store at ${STORE_DB}"
  fi
  if [[ -e "$PRISTINE_DIR" ]]; then
    die "${PRISTINE_DIR} already exists"
  fi
  log "capturing prstine copy of ${DATASET_ID} -> ${PRISTINE_DIR}"

  stop_neo4j
  mkdir -p "$PRISTINE_DIR"
  cp -a "$STORE_DB" "$PRISTINE_DIR/databases_${DATABASE}"
  if [[ -d "$STORE_TX" ]]; then
    cp -a "$STORE_TX" "$PRISTINE_DIR/transactions_${DATABASE}"
  else
    rm -rf "$PRISTINE_DIR"
    systemctl start neo4j
    die "Copy failed"
  fi
  sync
  BYTES="$(du -sb "$PRISTINE_DIR" | awk '{print $1}')" \
  FILES="$(find "$PRISTINE_DIR" -type f | wc -l)"
  {
    printf 'pristine_dir=%s\n' "$PRISTINE_DIR"
    printf 'pristine_bytes=%s\n' "$BYTES"
    printf 'pristine_files=%s\n' "$FILES"
  } >>"$STATE/neo4j_dataset"
  log "${FILES} files and $((BYTES / 1048576)) MB recorded in state file"
  SNAP="${STATE}/neo4j_dataset.sf${SF:-$(awk -F= '/^scale_factor=/{print $2}' "$STATE/neo4j_dataset")}"
  cp -f "$STATE/neo4j_dataset" "$SNAP"
  log "Switch between scalefactors with"
  log " sudo cp ${SNAP} ${STATE}/neo4j_dataset"
  systemctl start neo4j
  log "Copy done"
  exit 0
fi

log "Restoring database"
stop_neo4j

if [[ ! -d "$PRISTINE_DIR" ]]; then
  die "No pristine copy at $PRISTINE_DIR"
fi
rm -rf "${STORE_DB:?}" "${STORE_TX:?}"
cp -a "$PRISTINE_DIR/databases_${DATABASE}" "$STORE_DB"
if [[ -d "$PRISTINE_DIR/transactions_${DATABASE}" ]]; then
  mkdir -p "$(dirname "$STORE_TX")"
  cp -a "$PRISTINE_DIR/transactions_${DATABASE}" "$STORE_TX"
fi
sync

if find "$DATA_DIR" ! -user neo4j -print -quit 2>/dev/null | grep -q .; then
  log "Fixing ownership to neo4j"
  chown -R neo4j:neo4j "$DATA_DIR"
fi

systemctl start neo4j

AUTH_ARGS=(-u neo4j -p "admin")

for i in $(seq 1 45); do
  if OUT="$(cypher-shell -a bolt://127.0.0.1:7687 "${AUTH_ARGS[@]}" --format plain \
    "MATCH (n) RETURN count (n) AS n;" 2>&1)"; then
    NODES="$(tail -n +2 <<<"$OUT" | tr -dc '0-9')"
    break
  fi
  grep -qi "unauthorized\|authentication failure" <<<"$OUT" &&
    die "Authentication failed after restore"
  sleep 2
  if [[ $i -eq 45 ]]; then
    die "Neo4j did not come back after restore"
  fi
done

WANT_NODES="$(awk -F= '/^nodes=/{print $2}' "$STATE/neo4j_dataset" 2>/dev/null || true)"
if [[ "$NODES" != "$WANT_NODES" ]]; then
  die "Not an equal node count after import"
fi
log "Node count verified"
log "Restore done for ${DATABASE} $PRISTINE_DIR"
