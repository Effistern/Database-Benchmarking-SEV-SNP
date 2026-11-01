#!/usr/bin/env bash
set -euo pipefail

#--------------------------------------------------------------------------------
# Configuration
#--------------------------------------------------------------------------------

MAKE_PRISTINE=0;
WORKLOAD="";
WAREHOUSES="";
SCALE_FACTOR="";
REGIME="";
PRISTINE_DIR="";
PGDATA="";
PG_MAJOR="";
DROP_CACHES=1;
STATE="/var/lib/db-benchmark"
LOG="/var/log/postgres_restore.log"


#--------------------------------------------------------------------------------
# Argument parsing
#--------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
        case "$1" in
            --make-pristine)
                MAKE_PRISTINE=1;
                shift
                ;;
            --workload)
                WORKLOAD="${2:?ERROR: --workload requires a value}"
                shift 2
                ;;
            --warehouses)
                WAREHOUSES="${2:?ERROR: --warehouses requires a value}"
                shift 2
                ;;
            --scale-factor)
                SCALE_FACTOR="${2:?ERROR: --scale-factor requires a value}"
                shift 2
                ;;
            --regime)
                REGIME="${2:?ERROR: --regime requires a value}"
                shift 2
                ;;
            --pristine-dir)
                PRISTINE_DIR="${2:?ERROR: --pristine-dir requires a value}"
                shift 2
                ;;
            --pgdata)
                PGDATA="${2:?ERROR: --pgdata requires a value}"
                shift 2
                ;;
            --pg-major)
                PG_MAJOR="${2:?ERROR: --pg-major requires a value}"
                shift 2
                ;;
            --no-drop-caches)
                DROP_CACHES=0
                shift 
                ;;
            *)
                echo "ERROR: Unknown argument: $1" >&2
                exit 2
                ;;
        esac
done

log(){
    local line
    line="$(printf '[%s] %s' "$(date -u +%H:%M:%SZ)" "$*")"
    printf '%s\n' "$line" >&2
    { printf '%s\n' "$line" >> "$LOG"; } 2>/dev/null || true
}

die() {
    log "FATAL: $*";
    exit 1;
}

run() {
    "$@"
}

[[ "$EUID" -eq 0 ]] || die "must run as root"
mkdir -p "$STATE"
touch "$LOG" 2>/dev/null || true

#--------------------------------------------------------------------------------
# Locate cluster
#--------------------------------------------------------------------------------

if [[ -z "$PG_MAJOR" ]]; then
    PG_MAJOR="$(ls -1 /etc/postgresql 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1 || true)"
    [[ -n "$PG_MAJOR" ]] || die "could not detect the PostgreSQL major version"
fi
SERVICE="postgresql@${PG_MAJOR}-main"

if [[ -z "$PGDATA" ]]; then
    if [[ -f "$STATE/postgres_setup.json" ]]; then
        PGDATA="$(python3 -c "import json,sys; print(json.load(open('$STATE/postgres_setup.json')).get('datapath',''))" 2>/dev/null || true)"
    fi
    if [[ -z "$PGDATA" ]]; then
        PGDATA="$(awk -F\' '/^[[:space:]]*data_directory[[:space:]]*=/{print $2}' "/etc/postgresql/${PG_MAJOR}/main/postgresql.conf" 2>/dev/null | tail -1 || true)"
    fi
    [[ -n "$PGDATA" ]] || die "could not determine the cluster directory. Pass --pgdata."
fi

DATA_MOUNT="$(dirname "$PGDATA")"
PGBIN="/usr/lib/postgresql/${PG_MAJOR}/bin"

#--------------------------------------------------------------------------------
# Service control
#--------------------------------------------------------------------------------

stop_postgres() {
    log "stopping ${SERVICE}"
    run systemctl stop "$SERVICE"
    for _ in $(seq 1 60); do
        systemctl is-active --quiet "$SERVICE" || break
        sleep 1
    done
    if systemctl is-active --quiet "$SERVICE"; then
        die "${SERVICE} did not stop"
    fi
}

start_postgres() {
    log "   starting ${SERVICE}"
    run systemctl start "$SERVICE"
    for _ in $(seq 1 60); do
        sudo -u postgres "${PGBIN}/pg_isready" -q && return 0
        sleep 1
    done
    die "${SERVICE} did not become ready- check /var/log/postgresql/"
}

assert_cleanly_shut_down() {
    local st
    st="$(sudo -u postgres "${PGBIN}/pg_controldata" -D "$PGDATA" 2>/dev/null | awk -F: '/Database cluster state/{gsub(/^[ \t]+/,"", $2); print $2}')"
    [[ "$st" == "shut down" ]] || die "cluster state is '${st:-unknown}'."
}

#--------------------------------------------------------------------------------
#  Make Pristine
#--------------------------------------------------------------------------------

if [[ "$MAKE_PRISTINE" -eq 1 ]]; then
    case "$WORKLOAD" in
        tpcc)
            [[ -n "$WAREHOUSES" ]] || die "--warehouses required for tpcc."
            DATASET_ID="tpcc-w${WAREHOUSES}"; 
            SCALE_DESC="${WAREHOUSES} warehouses"
            ;;
        tproch)
            [[ -n "$SCALE_FACTOR" ]] || die "--scale-factor required for tproch."
            DATASET_ID="tproch-sf${SCALE_FACTOR}";
            SCALE_DESC="scale factor ${SCALE_FACTOR}"
            ;;
        "")
            die "--workload required with --make-pristine (tpcc|tproch)"
            ;;
        *)
            die "--workload must be tpcc or tproch"
            ;;
    esac
    case "$REGIME" in
        resident|exceeding)
            ;;
        "") die "--regime required with --make-pristine (resident|exceeding)"
            ;;
        *)
            die "--regime must be resident or exceeding"
            ;;
    esac

    [[ -n "$PRISTINE_DIR" ]] || PRISTINE_DIR="${DATA_MOUNT}/pristine_${DATASET_ID}"

    [[ ! -e "$PRISTINE_DIR" ]] || die "${PRISTINE_DIR} already exists."
        case "$WORKLOAD" in
            tpcc)
                ROWS="$(sudo -u postgres psql -tAc 'SELECT count(*) FROM warehouse;' tpcc 2>/dev/null || echo 0)"
                ROWS_TABLE="warehouse"
                ;;
            tproch)
                ROWS="$(sudo -u postgres psql -tAc 'SELECT count(*) FROM customer;' tpch 2>/dev/null || echo 0)"
                ROWS_TABLE="customer"
                ;;
        esac
        [[ "${ROWS:-0}" -gt 0 ]] || die "the ${WORKLOAD} database reports 0 rows in ${ROWS_TABLE}."

    stop_postgres
    assert_cleanly_shut_down

    if [[ -L "$PGDATA/pg_wal" ]]; then
        start_postgres
        die "pg_wal is a symlink to $(readlink -f "$PGDATA/pg_wal")."
    fi

    run mkdir -p "$PRISTINE_DIR"
    run cp -a "$PGDATA/." "$PRISTINE_DIR/"
    run sync

        BYTES="$(du -sb "$PRISTINE_DIR" | awk '{print $1}')"
        FILES="$(find "$PRISTINE_DIR" -type f | wc -l)"
        MEM_MB=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) /1024 ))
        {
            printf 'dataset_id=%s\n'        "$DATASET_ID"
            printf 'workload=%s\n'          "$WORKLOAD"
            printf 'regime=%s\n'            "$REGIME"
            printf 'warehouses=%s\n'        "${WAREHOUSES:-}"
            printf 'scale_factor=%s\n'      "${SCALE_FACTOR}"
            printf 'rows_table=%s\n'        "$ROWS_TABLE"
            printf 'rows=%s\n'              "$ROWS"
            printf 'pristine_dir=%s\n'      "$PRISTINE_DIR"
            printf 'pristine_bytes=%s\n'    "$BYTES"
            printf 'pristine_files=%s\n'    "$FILES"
            printf 'mem_total_mb=%s\n'      "$MEM_MB"
            printf 'captured_at_utc=%s\n'   "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf 'pg_major=%s\n'          "$PG_MAJOR"
        } > "$STATE/postgres_dataset"

        SNAP="${STATE}/postgres_dataset.${DATASET_ID}"
        cp -f "$STATE/postgres_dataset" "$SNAP"
    start_postgres
    log "done"
    exit 0
fi

#--------------------------------------------------------------------------------
#  Restore
#--------------------------------------------------------------------------------

[[ -f "$STATE/postgres_dataset" ]] || die "no state file at ${STATE}/postgres_dataset."

sf() {
    awk -F= -v k="$1" '$1==k{print $2}' "$STATE/postgres_dataset";
}

DATASET_ID="$(sf dataset_id)";
WORKLOAD="$(sf workload)";
REGIME="$(sf regime)";
WANT_BYTES="$(sf pristine_bytes)";
WANT_FILES="$(sf pristine_files)";
WANT_ROWS="$(sf rows)";
ROWS_TABLE="$(sf rows_table)"

[[ -n "$PRISTINE_DIR" ]] || PRISTINE_DIR="$(sf pristine_dir)"
[[ -n "$DATASET_ID" ]] || die "no dataset_id"

log "restoring ${DATASET_ID} (${WORKLOAD}, ${REGIME}) from ${PRISTINE_DIR}"

[[ -d "$PRISTINE_DIR" ]] || die "no pristine copy at ${PRISTINE_DIR}.´
        Create it once per dataset with --make-pristine."

if [[ -n "$WANT_BYTES" ]]; then
    GOT_BYTES="$(du -sb "$PRISTINE_DIR" | awk '{print $1}')"
    GOT_FILES="$(find "$PRISTINE_DIR" -type f | wc -l)"
    [[ "$GOT_BYTES" == "$WANT_BYTES" && "$GOT_FILES" == "$WANT_FILES" ]] || die "the pristine copy has changed since it was captured."
fi

if [[ -n "$WANT_BYTES" ]]; then
    AVAIL_KB="$(df --output=avail -k "$DATA_MOUNT" | tail -1 | tr -d ' ')"
    CURRENT_KB="$(du -sk "$PGDATA" 2>/dev/null | awk '{print $1}' || echo 0)"
    NEED_KB=$(( WANT_BYTES / 1024 ))
    MARGIN_KB=$(( 4 * 1024 * 1024 ))
    if (( NEED_KB + MARGIN_KB > AVAIL_KB + CURRENT_KB )); then
        die "not enough space on ${DATA_MOUNT}."
    fi
fi


stop_postgres

run rm -rf "${PGDATA:?refusing to rm -rf an empty PGDATA}"
run mkdir -p "$PGDATA"
run cp -a "$PRISTINE_DIR/." "$PGDATA/"
run chown -R postgres:postgres "$PGDATA"
run chmod 0700 "$PGDATA"
run sync

assert_cleanly_shut_down

if [[ "$DROP_CACHES" -eq 1 ]]; then
    log "dropping the OS page cache"
    run sync
    echo 3 > /proc/sys/vm/drop_caches || die "could not drop the page cache"
    sleep 2
else
    log "NOT dropping the page cache (--no-drop-caches)."
fi

start_postgres

if [[ -n "$WANT_ROWS" ]]; then
    case "$WORKLOAD" in
        tpcc)
            DB=tpcc
            ;;
        tproch)
            DB=tpch
            ;;
        *)
            DB=postgres
            ;;
    esac
    GOT_ROWS="$(sudo -u postgres psql -tAc "SELECT count(*) FROM ${ROWS_TABLE};" "$DB" 2>/dev/null || echo 0)"
    [[ "$GOT_ROWS" == "$WANT_ROWS" ]] || die "restored cluster has wrong rows"
fi

log "restored ${DATASET_ID}."