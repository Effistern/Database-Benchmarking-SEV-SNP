#!/usr/bin/env bash
set -euo pipefail

#--------------------------------------------------------------------------------
# Configuration
#--------------------------------------------------------------------------------

ARGV=("$@")
DETACH=0

CONFIG=""

DATASETS="tpcc-w20,tpcc-w260,tproch-sf1,tproch-sf10"
REPS=12
ROUND="campaign_postgres"
OUT_ROOT="./raw_results"
POWEROFF=0
MICROBENCH=1

PARAMS_tpcc_w20="2  2   5"
PARAMS_tpcc_w260="1  2   5"
PARAMS_tproch_sf1="1  0  0"
PARAMS_tproch_sf10="1  0  0"

THREADS=""
RAMPUP=""
DURATION=""

STATE="/var/lib/db-benchmark"
DATA_MOUNT="/mnt/dbdata"
MIN_FREE_MB=4096

#--------------------------------------------------------------------------------
# Argument parsing
#--------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG="${2:?--config requires a value}";
            shift 2
            ;;
        --dataset)
            DATASETS="${2:?}";
            shift 2
            ;;
        --repetitions)
            REPS="${2:?}";
            shift 2
            ;;
        --round)
            ROUND="${2:?}"
            shift 2
            ;;
        --threads)
            THREADS="${2:?}"
            shift 2
            ;;
        --rampup)
            RAMPUP="${2:?}"
            shift 2
            ;;
        --duration)
            DURATION="${2:?}"
            shift 2
            ;;
        --out)
            OUT_ROOT="${2:?}"
            shift 2
            ;;
        --state)
            STATE="${2:?}"
            shift 2
            ;;
        --detach)
            DETACH=1
            shift
            ;;
        --no-microbench)
            MICROBENCH=0
            shift
            ;;
        --poweroff-on-success)
            POWEROFF=1
            shift
            ;;
        *)
        echo "ERROR: unknown argument: $1" >&2;
        exit 2
        ;;
    esac
done

case "$CONFIG" in
    none|sev|snp);;
    "")
        echo "ERROR: --config required" >&2;
        exit 2
        ;;
    *)
        echo "ERROR: --config must be none|sev|snp" >&2;
        exit 2
        ;;
esac

[[ "$EUID" -eq 0 ]] || { echo "ERROR: must run as root" >&2; exit 2; }

if (( DETACH )) && [[ -z "${CAMPAIGN_DETACHED:-}" ]]; then
    UNIT="campaign-postgres-${CONFIG}-$(date -u +%Y%m%dT%H%M%SZ)"
    SELF="$(readlink -f "$0")"
    command -v systemd-run >/dev/null 2>&1 ||
        { echo "ERROR: --detach needs systemd-run" >&2; exit 2; }
    cat >&2 <<EOF

detaching as systemd unit: ${UNIT}

    follow: journalctl -u ${UNIT} -f
    status: systemctl status ${UNIT}

EOF
    exec systemd-run --unit="$UNIT" --working-directory="$PWD" --setenv=CAMPAIGN_DETACHED=1 "$SELF" "${ARGV[@]}"
fi

WORKDIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RUNNER="${WORKDIR}/run_benchmark.sh"
RESTORE="${WORKDIR}/restore.sh"
MICRO="${WORKDIR}/../common/run_microbench.sh"
LOG="${OUT_ROOT}/campaign_postgres_${CONFIG}_$(date -u +%Y%m%dT%H%M%SZ).log"

mkdir -p "$OUT_ROOT"
touch "$LOG"

log() {
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2 || true; 
}

die() {
    log "FATAL: $*";
    exit 2;
}

IFS=',' read -ra DS_ <<<"$DATASETS"

ds_param() {
    local key="PARAMS_${1//-/_}" idx="$2" vals
    vals="${!key:-}"
    [[ -n "$vals" ]] || return 0
    awk -v i="$idx" '{print $i}' <<<"$vals"
}

finish() {
    local d
    for d in ${DS_[@]+"${DS_[@]}"}; do
        [[ -d "${OUT_ROOT}/${ROUND}__${d}" ]] || continue
        cp -f "$LOG" "${OUT_ROOT}/${ROUND}__${d}/campaign.log" 2>/dev/null || true
    done
}
trap finish EXIT

#--------------------------------------------------------------------------------
# Pre-check
#--------------------------------------------------------------------------------

log "config=${CONFIG} dataset=${DATASETS} reps=${REPS}"

[[ -x "$RUNNER" ]] || die "run_benchmark.sh not found at ${RUNNER}"
[[ -x "$RESTORE" ]] || die "restore.sh not found at ${RESTORE}"

PG_MAJOR="$(ls -1 /etc/postgresql 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1 || true)"
[[ -n "$PG_MAJOR" ]] || die "no PostgreSQL cluster config "
PG_UNIT="postgresql@${PG_MAJOR}-main"
systemctl is-active --quiet "$PG_UNIT" || die "${PG_UNIT} is not running"

HAMMERDB_DIR="${HAMMERDB_DIR:-/opt/HammerDB-6.0}"
[[ -x "${HAMMERDB_DIR}/hammerdbcli" ]] || die "no hammercli at ${HAMMERDB_DIR}"

if (( MICROBENCH )); then
    [[ -x "$MICRO" ]] || die "--no-microbench not given"
    command -v sysbench >/dev/null 2>&1 || die "sysbench is installed."
fi

BIGGEST_KB=0
for d in "${DS_[@]}"; do
    SNAP="${STATE}/postgres_dataset.${d}"
    [[ -f "$SNAP" ]] || die "no state snapshot ${SNAP}"
        P="$(awk -F= '/^pristine_dir=/{print $2}' "$SNAP")"
        B="$(awk -F= '/^pristine_bytes=/{print $2}' "$SNAP")"
        W="$(awk -F= '/^workload=/{print $2}' "$SNAP")"
        R="$(awk -F= '/^regime=/{print $2}' "$SNAP")"
        [[ -d "$P" ]] || die "dataset ${d} needs ${P}"
        (( B / 1024 > BIGGEST_KB )) && BIGGEST_KB=$(( B / 1024 ))
        log "pre-check: ${d} -> ${W}/${R}, $(( B / 1048576 )) MB, verified"
done

AVAIL_KB="$(df -P --block-size=1K "$DATA_MOUNT" | awk 'NR==2{print $4}')"
CUR_KB="$(du -sk "${DATA_MOUNT}/postgresql" 2>/dev/null | awk '{print $1}' || echo 0)"
if (( BIGGEST_KB + MIN_FREE_MB * 1024 > AVAIL_KB + CUR_KB )); then
    die "not enough space on ${DATA_MOUNT}."
fi

#--------------------------------------------------------------------------------
# Run
#--------------------------------------------------------------------------------

microbench() {
    (( MICROBENCH )) || return 0
    log "   hardware control (${2}) -- ${1}"
    if "$MICRO" --config "$CONFIG" --round "${ROUND}__${1}" --phase "$2" --out "$OUT_ROOT"; then
        log "ok"
    else
        log "WARNING: hardware control ${2} FAILED"
    fi
}

FAILED=0
for d in "${DS_[@]}"; do
    log "=== dataset ${d}: ${REPS} repetitions ==="
    rm -f /tmp/*.db /tmp/*.DB /tmp/*.db-wal /tmp/.db-shm 2>/dev/null || true

    cp "${STATE}/postgres_dataset.${d}" "${STATE}/postgres_dataset" \
        || die "could not switch the state file to ${d}"

    microbench "$d" pre

    dT="${THREADS:-$(ds_param "$d" 1)}"
    dR="${RAMPUP:-$(ds_param "$d" 2)}"
    dD="${DURATION:-$(ds_param "$d" 3)}"
    log "threads=${dT} rampup=${dR} duration=${dD}"

    STARTED="$(date -u +%s)"
    if "$RUNNER" \
            --config "$CONFIG" \
            --round "${ROUND}__${d}" \
            --repetitions "$REPS" \
            --threads "$dT" \
            --rampup "$dR" \
            --duration "$dD" \
            --state "$STATE"; then
        log "dataset ${d}: COMPLETED in $(( ( $(date -u +%s) - STARTED ) / 60 )) min"
    else
        log "dataset ${d}: FAILED after $(( ( $(date -u +%s) - STARTED ) / 60 )) min"
        FAILED=$(( FAILED + 1 ))
    fi

    microbench "$d" post
done

#--------------------------------------------------------------------------------
# Summary
#--------------------------------------------------------------------------------

log "--------------------------------------------------------------"
for d in "${DS_[@]}"; do
    RD="${OUT_ROOT}/${ROUND}__${d}"
    N=$(find "$RD" -name manifest.json 2>/dev/null | wc -l)
    BAD=$({ find "$RD" -name manifest.json -exec grep -l '"succeeded": false' {} + 2>/dev/null || true; } | wc -l)
    log "${d}: ${N} manifest(s), ${BAD} reporting failure"
done
(( MICROBENCH )) && log "python3 ${WORKDIR}/../common/compare_microbench.py ${OUT_ROOT}/${ROUND}__<dataset>"

if (( FAILED )); then
    log "campaign finished with ${FAILED} failed dataset(s)"
    exit 1
fi

if (( POWEROFF )); then
    log "all dataset completed, syncing and powering off in 60s."
    sync; sleep 60; log "powering off"; shutdown -h now
fi

log "campaign complete"

exit 0