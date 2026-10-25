#!/usr/bin/env bash
set -euo pipefail

#--------------------------------------------------------------------------------
# Configuration
#--------------------------------------------------------------------------------

HAMMERDB_DIR="/opt/HammerDB-6.0"
DBUSER="postgres"
DBPASS="postgres"
BUILD_THREADS=4

DATASETS=(
    "tpcc       20      resident"
    "tpcc       260     exceeding"
    "tproch     1       resident"
    "tproch     10     exceeding"
)

sudo -u postgres psql -c "ALTER USER ${DBUSER} PASSWORD '${DBPASS}';" > /dev/null

#--------------------------------------------------------------------------------
# Helpers
#--------------------------------------------------------------------------------

log() {
    printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2
}

die() {
    log "FATAL: $*"; exit 1;
}

write_tcl() {
    if [[ "$1" == tpcc ]]; then
    cat << EOF
dbset db pg
dbset bm TPROC-C
diset connection pg_host localhost
diset connection pg_port 5432
diset tpcc pg_dbase tpcc
diset tpcc pg_user ${DBUSER}
diset tpcc pg_pass ${DBPASS}
diset tpcc pg_count_ware $2
diset tpcc pg_num_vu ${BUILD_THREADS}
buildschema
EOF
    else
    cat << EOF
dbset db pg
dbset bm TPROC-H
diset connection pg_host localhost
diset connection pg_port 5432
diset tpch pg_tpch_dbase tpch
diset tpch pg_tpch_user ${DBUSER}
diset tpch pg_tpch_pass ${DBPASS}
diset tpch pg_scale_fact $2
diset tpch pg_num_tpch_threads ${BUILD_THREADS}
buildschema
EOF
    fi
}


#--------------------------------------------------------------------------------
# Build TPROC-* Schema
#--------------------------------------------------------------------------------

for spec in "${DATASETS[@]}"; do
    sudo rm -f /tmp/*.db /tmp/*.DB /tmp/*.db-wal /tmp/*.db-shm /tmp/hammer*
    read -r wl scale regime <<<"$spec"
    db=$([[ "$wl" == tpcc ]] && echo tpcc || echo tpch)

    for d in tpcc tpch; do
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${d};"
    done
    sudo -u postgres createdb "$db"

    write_tcl "$wl" "$scale" > /tmp/build.tcl
    (cd "$HAMMERDB_DIR" && ./hammerdbcli auto /tmp/build.tcl) || die "$wl $scale build failed"

    sudo -u postgres psql -d "$db" -c "VACUUM ANALYZE;"

    WORKDIR=$(dirname "$(readlink -f "$0")")
    if [[ "$wl" == tpcc ]]; then
        sudo "${WORKDIR}/restore.sh" --make-pristine --workload tpcc --warehouses "$scale" --regime "$regime"
    else
        sudo "${WORKDIR}/restore.sh" --make-pristine --workload tproch --scale-factor "$scale" --regime "$regime"
    fi
done