#!/usr/bin/env bash
set -euo pipefail

#--------------------------------------------------------------------------------
# Configuration
#--------------------------------------------------------------------------------

CONFIG="";
PG_VERSION="16";
SHARED_BUFFERS_GB="4";
WORK_MEM_MB="256";
SYNC_COMMIT="off";
DATA_MOUNT="/mnt/dbdata";
PG_CORES="0,2";
USE_AFFINITY=1;
BIND_IP="127.0.0.1";

#--------------------------------------------------------------------------------
# Parsing
#--------------------------------------------------------------------------------


while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                CONFIG="${2:?ERROR: --config requires a value}"
                shift 2
                ;;
            --pg-version)
                PG_VERSION="${2:?ERROR: --pg-version requires a value}"
                shift 2
                ;;
            --shared-buffers-gb)
                SHARED_BUFFERS_GB="${2:?ERROR: --shared-buffers-gb requires a value}"
                shift 2
                ;;
            --work-mem-mb)
                WORK_MEM_MB="${2:?ERROR: --work-mem-mb requires a value}"
                shift 2
                ;;
            --sync-commit)
                SYNC_COMMIT="${2:?ERROR: --sync-commit requires a value}"
                shift 2
                ;;
            --data-mount)
                DATA_MOUNT="${2:?ERROR: --data-mount requires a value}"
                shift 2
                ;;
            --pg-cores)
                PG_CORES="${2:?ERROR: --pg-cores requires a value}"
                shift 2
                ;;
            --no-affinity)
                USE_AFFINITY=0
                shift
                ;;
            --bind-ip)
                BIND_IP="${2:?ERROR: --bind-ip requires a value}"
                shift 2
                ;;
            *)
                echo "ERROR: Unknown argument: $1" >&2
                exit 2
                ;;
        esac
done

case "$CONFIG" in 
        none|sev|snp) ;;
        "") echo "ERROR: --config required" >&2; exit 2 ;;
        *) echo "ERROR: --config must be none|sev|snp" >&2; exit 2 ;;
esac

if ! [[ "$SHARED_BUFFERS_GB" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --shared-buffers-gb must be an integer" >&2;
    exit 2
fi

if ! [[ "$WORK_MEM_MB" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --work-mem-mb must be an integer (0 = leave the PostgreSQL default)" >&2;
    exit 2
fi

case "$SYNC_COMMIT" in
    on|off|local|remote_write|remote_apply) ;;
    *) echo "ERROR: --sync-commit must be  on|off|local|remote_write|remote_apply" >&2; exit 2 ;;
esac

LOGDIR="/var/log/postgresql"
STATE="/var/lib/db-benchmark"
LOG="/var/log/postgres_setup.log"

mkdir -p "$STATE";
touch "$LOG";

#--------------------------------------------------------------------------------
# Helper
#--------------------------------------------------------------------------------

log() {
    printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" |
    tee -a "$LOG" >&2 || true
}

die() {
    log "FATAL: $*";
    exit 1;
}

run() {
    "$@"
}

log "PostgreSQL setup - config=$CONFIG version=$PG_VERSION shared_buffers=${SHARED_BUFFERS_GB}G"

#--------------------------------------------------------------------------------
# Guards
#--------------------------------------------------------------------------------

mountpoint -q "$DATA_MOUNT" 2>/dev/null ||
    die "Data mount is not mounted: $DATA_MOUNT"
MEM_KB=$(grep '^MemTotal:' /proc/meminfo | awk '{printf $2}')
MEM_MB=$((MEM_KB / 1024))
BUFFERS_MB=$((SHARED_BUFFERS_GB * 1024))
log "MemTotal ${MEM_MB} MB, requested shared_buffers ${BUFFERS_MB} MB"
if (( BUFFERS_MB > MEM_MB * 50 / 100)); then
    die "shared_buffers ${SHARED_BUFFERS_GB} GB. Needs more space."
fi

#--------------------------------------------------------------------------------
# Postgres Install
#--------------------------------------------------------------------------------

CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
KEYRING="/usr/share/keyrings/postgresql-archive-keyring.gpg"
LISTFILE="/etc/apt/sources.list.d/pgdg.list"

if command -v psql >/dev/null 2>&1; then
    HAVE="$(psql --version | awk '{print $3}' | cut -d. -f1)"
    log "PostgreSQL installed, major version: $HAVE"
    case "$HAVE" in
        "$PG_VERSION"*)
            log "version machtes the bin" ;;
        *)
            die "installed PostgreSQL major version $HAVE does not match --pg-version $PG_VERSION." ;;
    esac
else
    log "adding PostgreSQL PGDG apt repository for Ubuntu $CODENAME"
    run bash -c "curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor -o '${KEYRING}' --yes" \
        || die "could not fetch PostgreSQL GPG signing key"

    run bash -c "echo 'deb [arch=amd64,arm64 signed-by=${KEYRING}] http://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main' \
        > '${LISTFILE}'"
    run env DEBIAN_FRONTEND=noninteractive apt-get update -qq || die "apt-get update failed"
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq\
        "postgresql-${PG_VERSION}" ||
            die "postgresql-${PG_VERSION} install failed"
    run apt-mark hold "postgresql-${PG_VERSION}" >/dev/null
    log "installed and version-held"
fi

#--------------------------------------------------------------------------------
# Configuration
#--------------------------------------------------------------------------------

run systemctl stop postgresql || true
PG_DATA="/mnt/dbdata/postgresql"
if [[ ! -d "$PG_DATA" ]]; then
    mkdir -p "$PG_DATA"
    chown postgres:postgres $PG_DATA
    if [[ -d "/var/lib/postgresql/$PG_VERSION/main" ]]; then
        rsync -av "/var/lib/postgresql/$PG_VERSION/main/" "$PG_DATA"
    else
        run sudo -u postgres "/usr/lib/postgresql/$PG_VERSION/bin/initdb" -D "$PG_DATA"
    fi
fi

run mkdir -p "$LOGDIR"
run chown -R postgres:postgres "$DATA_MOUNT/postgresql" "$LOGDIR"

CONF_FILE="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"


[[ -f "$CONF_FILE" ]] && cp -a "$CONF_FILE" "${CONF_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)"

sed -i "s|^data_directory =.*|data_directory = '${PG_DATA}'|" "$CONF_FILE"
sed -i "s|^listen_addresses =.*|listen_addresses = '${BIND_IP}'|" "$CONF_FILE"
sed -i "s|^shared_buffers =.*|shared_buffers = '${SHARED_BUFFERS_GB}GB'|" "$CONF_FILE"

cat >> "$CONF_FILE" <<EOF

logging_collector = on
log_directory = '${LOGDIR}'
log_filename = 'postgresql.log'
EOF
if [[ "$WORK_MEM_MB" -gt 0 ]]; then
printf 'work_mem = %sMB\n' "$WORK_MEM_MB" >> "$CONF_FILE"
fi

printf 'synchronous_commit = %s\n' "$SYNC_COMMIT" >> "$CONF_FILE"

printf 'effective_cache_size = %sGB\n' "$(( SHARED_BUFFERS_GB + 8))" >> "$CONF_FILE"

#--------------------------------------------------------------------------------
# CPU affinity
#--------------------------------------------------------------------------------

AFFINITY_DIR="/etc/systemd/system/postgresql@${PG_VERSION}-main.service.d"
AFFINITY_FILE="${AFFINITY_DIR}/10-cpuaffinity.conf"

if [[ "$USE_AFFINITY" -eq 1 ]]; then
    log "pinning postgresql to CPUs ${PG_CORES}"
    run mkdir -p "$AFFINITY_DIR"
    cat > "$AFFINITY_FILE" <<EOF
[Service]
CPUAffinity=${PG_CORES//,/ }
EOF
else
    log "not pinning postgresql (--no-affinity)"
    run rm -f "$AFFINITY_FILE"
fi

#--------------------------------------------------------------------------------
# Start and Verify
#--------------------------------------------------------------------------------

run systemctl daemon-reload
run systemctl enable postgresql >/dev/null 2>&1 || true
run systemctl restart postgresql

for i in $(seq 1 30); do
    sudo -u postgres pg_isready -h "$BIND_IP" >/dev/null 2>&1 && break
    sleep 2
    [[ $i -eq 30 ]] && die "postgresql not reachable - check logs under ${LOGDIR}"
done
log "postgresql is up"

EFF_BUFFERS="$(sudo -u postgres psql -t -A -c "SHOW shared_buffers;" 2>/dev/null)"
EFF_WORK_MEM="$(sudo -u postgres psql -t -A -c "SHOW work_mem;" 2>/dev/null)"
EFF_EFF_CACHE="$(sudo -u postgres psql -t -A -c "SHOW effective_cache_size;" 2>/dev/null)"
EFF_SYNC="$(sudo -u postgres psql -t -A -c "SHOW synchronous_commit;" 2>/dev/null)"

if [[ "$WORK_MEM_MB" -gt 0 && "$EFF_WORK_MEM" != "${WORK_MEM_MB}MB" ]]; then
    die "work_mem is ${EFF_WORK_MEM}, expected ${WORK_MEM_MB} MB."
fi

EFF_PATH="$(sudo -u postgres psql -t -A -c "SHOW data_directory;" 2>/dev/null)"
DEV_DATA="$(findmnt -no SOURCE "$DATA_MOUNT")"
log "data_directory=${EFF_PATH} on ${DEV_DATA}"
[[ "$EFF_PATH" == "$PG_DATA" ]] || die "data_directory is ${EFF_PATH}"

ACT_AFF="$(systemctl show "postgresql@${PG_VERSION}-main.service" -p CPUAffinity --value || true)"
log "postgresql CPUAffinity (systemd): ${ACT_AFF:-<none>}"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
python3 "$SCRIPT_DIR/write_postgres_setup.py" \
  "$STATE/postgres_setup.json" \
  "$CONFIG" \
  "$SHARED_BUFFERS_GB" \
  "$EFF_BUFFERS" \
  "$WORK_MEM_MB" \
  "$EFF_WORK_MEM" \
  "$EFF_EFF_CACHE" \
  "$SYNC_COMMIT" \
  "$EFF_SYNC" \
  "$PG_DATA" \
  "$DEV_DATA" \
  "$BIND_IP" \
  "$ACT_AFF" \
  "$USE_AFFINITY" \
  "$MEM_MB"

log "state written to $STATE/postgres_setup.json"
log "PostgreSQL installed, done"