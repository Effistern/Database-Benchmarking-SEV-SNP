#!/usr/bin/env bash
set -euo pipefail


source "$(dirname "$(readlink -f "$0")")/lib.sh"
#--------------------------------------------------------
#Configuration
#--------------------------------------------------------

YCSB_VERSION="0.17.0";
JDK="17";
PREFIX="/opt";

#--------------------------------------------------------
#Argument Parsing
#--------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ycsb-version) YCSB_VERSION="${2:?ERROR: --ycsb-version requires a value}";   shift 2 ;;
    --jdk)          JDK="${2:?ERROR: --jdk requires a value}";                     shift 2 ;;
    --prefix)       PREFIX="${2:?ERROR: --prefix requires a value}";               shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

YCSB_HOME="${PREFIX}/ycsb-${YCSB_VERSION}"
TARBALL="ycsb-mongodb-binding-${YCSB_VERSION}.tar.gz"
URL="https://github.com/brianfrankcooper/YCSB/releases/download/${YCSB_VERSION}/${TARBALL}"
LOG="/var/log/mongodb_install_ycsb.log"

BENCH_LOG="$LOG"
lib_init

#--------------------------------------------------------
#Java Install
#--------------------------------------------------------

PACKAGE="openjdk-${JDK}-jre-headless"
if ! dpkg-query -W -f ='${Status}' "$PACKAGE" 2>/dev/null |
  grep -q "ok installed"; then
    log "Installing $PACKAGE"
    run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    run env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y -qq "$PACKAGE" \
            || die "Could not install the JDK: $PACKAGE."
fi

JAVA_HOME_PATH="/usr/lib/jvm/java-${JDK}-openjdk-amd64"
if [[ ! -x "$JAVA_HOME_PATH/bin/java" ]]; then
    die "Expected Java at $JAVA_HOME_PATH"
fi

#--------------------------------------------------------
#YCSB Install
#--------------------------------------------------------

if [[ -d "$YCSB_HOME" ]]; then
  log "YCSB already present at $YCSB_HOME"
else
  log "Downloading YCSB release build"
  run curl -fsSL "$URL" -o "/tmp/$TARBALL" ||
    die "Download failed."
  run mkdir -p "$PREFIX"
  run tar -xzf "/tmp/$TARBALL" -C "$PREFIX" ||
    die "Unzipping tarball failed."

  if [[ -d "$PREFIX/ycsb-mongodb-binding-$YCSB_VERSION" ]]; then
    run mv \
      "$PREFIX/ycsb-mongodb-binding-$YCSB_VERSION" \
      "$YCSB_HOME"
  else
    die "Expected YCSB directory not found after extraction."
  fi

  run rm -f "/tmp/$TARBALL"
  log "Installed YCSB at $YCSB_HOME"
fi

#--------------------------------------------------------
#JDK pinning
#--------------------------------------------------------
cat > /etc/profile.d/ycsb.sh <<-EOF
export YCSB_HOME=${YCSB_HOME}
export JAVA_HOME=${JAVA_HOME_PATH}
export PATH=\$YCSB_HOME/bin:\$PATH
EOF
chmod 0644 /etc/profile.d/ycsb.sh
log "Pinned YCSB java version"

#--------------------------------------------------------
#Quick test
#--------------------------------------------------------

log "YCSB Test run"
command -v mongosh >/dev/null 2>&1 ||
  die "MongoDB not installed"
mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1 ||
  die "MongoDB not reachable"
log "Loading 100 records via YCSB"
export JAVA_HOME="$JAVA_HOME_PATH"
if "$YCSB_HOME/bin/ycsb.sh" load mongodb -s \
  -P "$YCSB_HOME/workloads/workloada" \
  -p recordcount=100 \
  -p operationcount=100 \
  -p mongodb.url="mongodb://127.0.0.1:27017/ycsb_testrun?w=1" \
  > /tmp/ycsb_smoke.log 2>&1; then
  COUNT="$(
    mongosh --quiet ycsb_testrun \
            --eval 'db.usertable.countDocuments({})' \
            2>/dev/null ||
            echo 0
  )"
  if [[ "$COUNT" != 100 ]]; then
    die "Test didnt pass, didnt match expected document count"
  fi
  mongosh --quiet ycsb_testrun \
          --eval 'db.dropDatabase()' \
          >/dev/null 2>&1 || true
          log "Test run passed, test database dropped"
else
  die "Test failed. Most likely incompatible setups"
fi

log "YCSB installation done"