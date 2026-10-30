#!/usr/bin/env bash
set -euo pipefail


source "$(dirname "$(readlink -f "$0")")/lib.sh"

#--------------------------------------------------------
#Configuration
#--------------------------------------------------------

CONFIG="";
MONGO_VERSION="8.0";
CACHE_GB=6;
DATA_MOUNT="/mnt/dbdata"
MONGO_CORES="0,2"
USE_AFFINITY=1;
BIND_IP="127.0.0.1";

#--------------------------------------------------------
#Argument parsing
#--------------------------------------------------------

while [[ $# -gt 0 ]];do
  case "$1" in
    --config)         CONFIG="$(arg_value "$@")";         shift 2 ;;
    --mongo-version)  MONGO_VERSION="$(arg_value "$@")";  shift 2 ;;
    --cache-gb)       CACHE_GB="$(arg_value "$@")";       shift 2 ;;
    --data-mount)     DATA_MOUNT="$(arg_value "$@")";     shift 2 ;;
    --mongo-cores)    MONGO_CORES="$(arg_value "$@")";    shift 2 ;;
    --no-affinity)    USE_AFFINITY=$(arg_flag);           shift   ;;
    --bind-ip)        BIND_IP="$(arg_value "$@")";        shift 2 ;;
    *)                echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

validate_config "$CONFIG"

if ! [[ "$CACHE_GB" =~ ^[0-9]+$ ]]; then
  die "--cache-gb must be an integer"
fi

DBPATH="$DATA_MOUNT/mongodb"
LOGDIR="/var/log/mongodb"
STATE="/var/lib/db-benchmark"

BENCH_LOG="$LOGDIR/setup.log"

mkdir -p "$STATE"
lib_init

#--------------------------------------------------------
#Guards
#--------------------------------------------------------

log "MongoDB setup - config=$CONFIG version=$MONGO_VERSION cache=${CACHE_GB}GB"

require_mount "$DATA_MOUNT"

MEM_KB=$(grep '^MemTotal:' /proc/meminfo | awk '{print $2}')
MEM_MB=$((MEM_KB / 1024))
CACHE_MB=$((CACHE_GB * 1024))
log "MemTotal ${MEM_MB} MB, Planned WireTiger cache ${CACHE_MB} MB"
if (( CACHE_MB > MEM_MB * 60 / 100 )); then
  die "Cache is more than 60% of total memory, YCSB JVM and OS also needs memory"
fi

#--------------------------------------------------------
#Mongo install
#--------------------------------------------------------
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
KEYRING="/usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg"
LISTFILE="/etc/apt/sources.list.d/mongodb-org-${MONGO_VERSION}.list"

if command -v mongod >/dev/null 2>&1; then
  VERSION=$(mongod --version | awk '/db version/{print $3}')
  log "MongoDB already installed. Version: $VERSION"
  case "$VERSION" in
  "v${MONGO_VERSION}"*)
    log "Installed version matches the pinned version";;
  *)
    die "Installed version does not match pinned version. Remove it or adjust the pin";;
  esac
else
  for stale in /etc/apt/sources.list.d/mongodb-org-*.list; do
    [[ -e "$stale" ]] || continue
    [[ "$stale" == "$LISTFILE" ]] && continue
    log "Deleting stale MongoDB sources $stale"
    run rm -f "$stale"
  done

  log "Adding MongoDB $MONGO_VERSION repository for Ubuntu $CODENAME"

  run bash -c "
      curl -fsSL https://pgp.mongodb.com/server-${MONGO_VERSION}.asc |
      gpg -o '${KEYRING}' --dearmor --yes" ||
      die "Couldn't fetch MongoDB signing key"

  cat > "$LISTFILE" <<EOF

  deb [ arch=amd64,arm64 signed-by=${KEYRING} ] https://repo.mongodb.org/apt/ubuntu ${CODENAME}/mongodb-org/${MONGO_VERSION} multiverse
EOF

  run env DEBIAN_FRONTEND=noninteractive apt-get update -qq \
  || die "Apt update failed."

  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mongodb-org \
  || die "MongoDB install failed"

  run apt-mark hold mongodb-org mongodb-org-server mongodb-org-mongos mongodb-org-tools mongodb-database-tools
  log "Installation done and version-held"
fi

#--------------------------------------------------------
#Configuration of MongoDB
#--------------------------------------------------------

run mkdir -p "$DBPATH" "$LOGDIR"
run chown -R mongodb:mongodb "$DBPATH" "$LOGDIR"
log "Writing /etc/mongod.conf"

if [[ -f /etc/mongod.conf ]]; then
  cp -a /etc/mongod.conf "/etc/mongod.conf.bak.$(date -u +%Y%m%dT%H%M%SZ)"
fi
cat > /etc/mongod.conf <<EOF
storage:
  dbPath: ${DBPATH}
  wiredTiger:
    engineConfig:
      cacheSizeGB: ${CACHE_GB}
systemLog:
  destination: file
  logAppend: true
  path: ${LOGDIR}/mongod.log
net:
  port: 27017
  bindIp: ${BIND_IP}
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
EOF

#--------------------------------------------------------
#CPU Pinning
#--------------------------------------------------------

AFFINITY_DIR="/etc/systemd/system/mongod.service.d"
AFFINITY_FILE="${AFFINITY_DIR}/10-cpuaffinity.conf"

if [[ $USE_AFFINITY -eq 1 ]]; then
  log "Pinning mongod to the following cores: ${MONGO_CORES}"
  if command -v lscpu >/dev/null 2>&1; then
    CORES_USED="$(
      lscpu -p=CPU,CORE |
      awk -F, -v cpus="$MONGO_CORES" '
        BEGIN {
          n = split(cpus, wanted, ",")
          for (i=1; i<=n; i++)
            cpu[wanted[i]] = 1
        }
        /^#/ { next }
        $1 in cpu {
          cores[$2] = 1
        }
        END {
          for (core in cores)
            printf "%s ", core
        }
      '
    )"
    if [[ "$(wc -w <<< "$CORES_USED")" -gt 1 ]]; then
      log " Mongod spans more than one physical core. The client will share cores with Mongodb"
    fi
  fi
  run mkdir -p "$AFFINITY_DIR"
    cat > "$AFFINITY_FILE" <<EOF
    [Service]
    CPUAffinity=${MONGO_CORES}
EOF
else
  log "not pinning mongod (--no-affinity)"
  run rm -f "$AFFINITY_FILE"
fi

#--------------------------------------------------------
#Check up if successful
#--------------------------------------------------------

run systemctl daemon-reload
run systemctl enable mongod >/dev/null 2>&1 || true
run systemctl restart mongod

wait_for_mongod
log "MongoDB is up and running"

EFF_CACHE="$(
  mongosh --quiet --eval \
    'db.serverStatus().wiredTiger.cache["maximum bytes configured"]' 2>/dev/null\
    | tr -dc '0-9'
  )"
EFF_CACHE_GB=$(( EFF_CACHE / 1024 / 1024 / 1024))
log "Effective WiredTiger cache: ${EFF_CACHE_GB} GB (Choosen by Setup ${CACHE_GB})"
if (( EFF_CACHE_GB != CACHE_GB )); then
  die "Cache is ${EFF_CACHE_GB}GB but not Setup chosen one ${CACHE_GB}GB"
fi
EFF_PATH="$(
  mongosh --quiet --eval \
  'db.adminCommand({getCmdLineOpts:1}).parsed.storage.dbPath' \
  2>/dev/null |
  tr -d '"'"'"'\r' |
  head -1
)"

DEV_DATA="$(findmnt -no SOURCE "$DATA_MOUNT")"
log "dbPath=${EFF_PATH} on ${DEV_DATA}"
if [[ "$EFF_PATH" != "$DBPATH" ]]; then
    die "dbPath is ${EFF_PATH}, expected ${DBPATH}"
fi
ACT_AFF="$(systemctl show mongod.service -p CPUAffinity --value || true)"
log "mongod CPUAffinity (systemd): ${ACT_AFF:-<none>}"

MONGO_PID="$(systemctl show mongod.service -p MainPID --value || echo 0)"

if [[ "${MONGO_PID:-0}" -gt 0 ]] && command -v taskset >/dev/null 2>&1; then

  ACT_MASK="$(
    taskset -cp "$MONGO_PID" 2>/dev/null |
      sed 's/.*: //' ||
      echo unknown
      )"

      log "Mongod process affinity (taskset): CPUs ${ACT_MASK}"

      if [[ "$USE_AFFINITY" -eq 1 && "$ACT_MASK" != "$MONGO_CORES" ]]; then
        log "WARNING: running process is on CPUs '${ACT_MASK}' but"
        log "'${MONGO_CORES}' was requested."
      fi
fi

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
python3 "$SCRIPT_DIR/write_mongodb_setup.py" \
  "$STATE/mongodb_setup.json" \
  "$CONFIG" \
  "$CACHE_GB" \
  "$EFF_CACHE" \
  "$DBPATH" \
  "$DEV_DATA" \
  "$BIND_IP" \
  "$ACT_AFF" \
  "$USE_AFFINITY" \
  "$MEM_MB"

log "state written to $STATE/mongodb_setup.json"
log "MongoDB installation done"