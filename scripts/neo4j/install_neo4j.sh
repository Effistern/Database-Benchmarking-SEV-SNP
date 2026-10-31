#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------
# Variables
# -----------------------------------------------------------------

CONFIG=""
NEO4J_VERSION=1:4.4.24
HEAP_GB=4
PAGECACHE_GB=6
DATA_MOUNT="/mnt/dbdata"
NEO4J_CORES="0,2"
PASSWORD="admin"

LOGDIR="/var/log/neo4j"
GCLOG="$LOGDIR/gc.log"
STATE="/var/lib/db-benchmark"
LOG="/var/log/neo4j_setup.log"
CONF="/etc/neo4j/neo4j.conf"
KEYRING="/usr/share/keyrings/neo4j.gpg"
LISTFILE="/etc/apt/sources.list.d/neo4j.list"

# -----------------------------------------------------------------
# Parsing
# -----------------------------------------------------------------

while (($#)); do
  case "$1" in
  --config)
    CONFIG="${2:?Missing value for --config}"
    shift 2
    ;;
  --heap-gb)
    HEAP_GB="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --pagecache-gb)
    PAGECACHE_GB="${2:?Missing value for --pachecache-gb}"
    shift 2
    ;;
  --mount)
    DATA_MOUNT="${2:?Missing value for --mount}"
    shift 2
    ;;
  *)
    echo "ERROR: Unknow argument: $1" >&2
    exit 2
    ;;
  esac
done

case $CONFIG in
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

for name in HEAP_GB PAGECACHE_GB; do
  value=${!name}
  case "$value" in
  '' | *[!0-9]*])
    echo "ERROR: $name must be a non-negative integer" >&2
    exit 2
    ;;
  esac
done

DATADIR="$DATA_MOUNT/neo4j/data"
TRANSACTIONDIR="$DATA_MOUNT/neo4j/transactions"

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

mkdir -p "$STATE" "$LOGDIR"
touch "$LOG"
log "Neo4j install setup. Config: $CONFIG, Heap: ${HEAP_GB}G, Pagecache: ${PAGECACHE_GB}G"

# -----------------------------------------------------------------
# Functional guards
# -----------------------------------------------------------------

mountpoint -q "$DATA_MOUNT" 2>/dev/null ||
  die "$DATA_MOUNT is not a valid mount. Testing on a local VM right now?"
while read -r key value _; do
  if [[ "$key" == "MemTotal:" ]]; then
    MEM_MB=$((value / 1024))
    break
  fi
done </proc/meminfo
TOTAL_MB=$(((HEAP_GB + PAGECACHE_GB) * 1024))
if ((TOTAL_MB > MEM_MB * 70 / 100)); then
  die "Heap + Pagecache is more than 70%. Leave some headroom for the LDBC driver"
fi

# ---------------------------------------------------------------------------
# Neo4j and java 11 installation
# ---------------------------------------------------------------------------

if command -v neo4j >/dev/null 2>&1; then
  VERSION=$(neo4j --version 2>/dev/null || echo "Unknown version")
  log "Neo4j already installed,version: $VERSION"
else
  log "Adding apt repository"
  curl -fsSL https://debian.neo4j.com/neotechnology.gpg.key |
    gpg --dearmor -o "$KEYRING" ||
    die "Could not fetch signing key"
  echo "deb [signed-by=${KEYRING}] https://debian.neo4j.com stable 4.4" \
    >"$LISTFILE"
  apt-get update -qq
  log "Installing OpenJDK 11 for Neo4j 4.4.24"
  apt-get install -y -qq openjdk-11-jdk-headless
  log "Installing Neo4j version 4.4.24"
  apt-get install -y -qq "neo4j=${NEO4J_VERSION}"
  apt-mark hold neo4j
  log "Installed Neo4j and version-held"
fi
# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

systemctl stop neo4j >/dev/null 2>&1 || true

mkdir -p "$DATADIR" "$TRANSACTIONDIR"
chown -R neo4j:neo4j "$DATADIR" "$TRANSACTIONDIR" "$LOGDIR" 2>/dev/null || true

JAVA_HOME_DIR="/usr/lib/jvm/java-11-openjdk-amd64"
if [[ -x "$JAVA_HOME_DIR/bin/java" ]]; then
  log "Installing Openjdk-11"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "openjdk-11-jdk-headless" ||
    die "Java 11 was not found. Re-run install or do it manually"
fi

DEFAULTS="/etc/default/neo4j"
touch "$DEFAULTS"

if grep -q '^JAVA_HOME=' "$DEFAULTS"; then
  sed -i "s|^JAVA_HOME=.*|JAVA_HOME=${JAVA_HOME_DIR}|" "$DEFAULTS"
else
  echo "JAVA_HOME=${JAVA_HOME_DIR}" >>"$DEFAULTS"
fi

log "Writing $CONF"

if [[ -f "$CONF" ]]; then
  cp -a "$CONF" "${CONF}.bak.$(date -u +%H:%M:%SZ)"
  cat >"$CONF" <<EOF
dbms.directories.data=${DATADIR}
dbms.directories.transaction.logs.root=${TRANSACTIONDIR}
dbms.directories.logs=${LOGDIR}
dbms.memory.heap.initial_size=${HEAP_GB}g
dbms.memory.heap.max_size=${HEAP_GB}g
dbms.memory.pagecache.size=${PAGECACHE_GB}g
dbms.default_listen_address=127.0.0.1
dbms.security.auth_enabled=true
MIN_PW_LINE=""
dbms.connector.bolt.enabled=true
dbms.connector.bolt.listen_address=127.0.0.1:7687
dbms.connector.http.enabled=false
dbms.connector.https.enabled=false
dbms.checkpoint=PERIODIC
dbms.checkpoint.interval.time=15m
dbms.checkpoint.interval.tx=100000
dbms.jvm.additional=-XX:+UseG1GC
dbms.jvm.additional=-XX:+AlwaysPreTouch
dbms.jvm.additional=-XX:+DisableExplicitGC
dbms.jvm.additional=-Xlog:gc*,safepoint:file=${GCLOG}:time,uptime,level,tags:filecount=5,filesize=20m
EOF
else
  die "Neo4j configuration was not found"
fi

if [[ "$PASSWORD" != "admin" ]]; then
  die "The scripts downstream require admin as password."
fi
log "Setting the Neo4j users password"

if ! PW_OUT=$(neo4j-admin set-initial-password "$PASSWORD" 2>&1); then
  printf '%s\n' "$PW_OUT" >&2
  die "Could not set the initial password"
fi

log "Pining java version for neo4j"
JAVA_DROPIN_DIR="/etc/systemd/system/neo4j.service.d"
JAVA_DROPIN="${JAVA_DROPIN_DIR}/05-java-home.conf"
mkdir -p "$JAVA_DROPIN_DIR"
cat >"$JAVA_DROPIN" <<EOF
[Service]
Environment=JAVA_HOME=${JAVA_HOME_DIR}
EOF

log "Pining neo4j to CPU cores"
AFFINITY_DIR="/etc/systemd/system/neo4j.service.d"
AFFINITY_FILE="${AFFINITY_DIR}/10-affinity.conf"
mkdir -p "$AFFINITY_DIR"
cat >"$AFFINITY_FILE" <<EOF
[Service]
CPUAffinity=${NEO4J_CORES}
EOF

# ---------------------------------------------------------------------------
# Start and verify
# ---------------------------------------------------------------------------

log "Starting neo4j and verifying"

systemctl daemon-reload
systemctl enable neo4j >/dev/null 2>&1 || true
systemctl start neo4j

AUTH_ARGS=(-u neo4j -p "$PASSWORD")

for i in $(seq 1 45); do
  cypher-shell -a "bolt://127.0.0.1:7687" "${AUTH_ARGS[@]}" \
    --format plain "RETURN 1;" >/dev/null 2>&1 && break
  sleep 2
  if [[ $i -eq 45 ]]; then
    die "Neo4j did not become reachable. Check logs and especially for Java 11"
  fi
done

log "Neo4j is up, verified and running."

{
  printf 'config=%s\n' "$CONFIG"
  printf 'neo4j_version=%s\n' "$NEO4J_VERSION"
  printf 'heap_gb=%s\n' "$HEAP_GB"
  printf 'pagecache=%s\n' "$PAGECACHE_GB"
  printf 'java_home=%s\n' "$JAVA_HOME_DIR"
  printf 'data_dir=%s\n' "$DATADIR"
  printf 'tx_dir=%s\n' "$TRANSACTIONDIR"
  printf 'cores=%s\n' "$NEO4J_CORES"
} >"$STATE/neo4j_setup"

log "Installation done!"
