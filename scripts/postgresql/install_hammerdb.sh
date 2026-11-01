#!/usr/bin/env bash
set -euo pipefail

#--------------------------------------------------------------------------------
# Configuration
#--------------------------------------------------------------------------------

HAMMERDB_VERSION="6.0-1";
PREFIX="/opt";

#--------------------------------------------------------------------------------
# Argument parsing
#--------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hammerdb-version)
            HAMMERDB_VERSION="${2:?ERROR: --hammerdb-version requires a value}"
            shift 2
            ;;
        --prefix)
            PREFIX="${2:?ERROR: --prefix requires a value}"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

VERSION="${HAMMERDB_VERSION%%-*}"
HAMMERDB_HOME="${PREFIX}/HammerDB-${VERSION}"
DEB_FILE="hammerdb_${HAMMERDB_VERSION}_amd64.deb"
URL="https://github.com/TPC-Council/HammerDB/releases/download/v${VERSION}/${DEB_FILE}"

LOG="/var/log/hammerdb.log"
STATE="/var/lib/db-benchmark"

mkdir -p "$STATE"
touch "$LOG";

#--------------------------------------------------------------------------------
# Standard functions
#--------------------------------------------------------------------------------

log() {
    printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" |
    tee -a "$LOG" >&2 || true
}

die () {
    log "FATAL: $*";
    exit 1;
}

run() {
    "$@"
}

#--------------------------------------------------------------------------------
# HammerDB Install
#--------------------------------------------------------------------------------

if [[ -d "$HAMMERDB_HOME" ]]; then
    log "HammerDB already present at $HAMMERDB_HOME"
else
    log "Downloading HammerDB release build (${HAMMERDB_VERSION})"
    run curl -fsSL "$URL" -o "/tmp/$DEB_FILE" ||
        die "Download failed."

    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "/tmp/$DEB_FILE" ||
        die "Couldn't install HammerDB."
    rm -f "/tmp/$DEB_FILE"
    log "Installed HammerDB at $HAMMERDB_HOME"
fi

#--------------------------------------------------------------------------------
# Quick Test
#--------------------------------------------------------------------------------

export PATH="${HAMMERDB_HOME}:$PATH"

if command -v hammerdbcli >/dev/null 2>&1; then
    log "HammerDB verified."
else
    die "HammerDB CLI not found in ${HAMMERDB_HOME}"
fi

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
python3 "$SCRIPT_DIR/write_hammerdb_install.py" \
  "$HAMMERDB_VERSION" \
  "$VERSION" \
  "$HAMMERDB_HOME" \
  "$STATE"

log "state written to $STATE/hammerdb_setup.json"

log "HammerDB install done"