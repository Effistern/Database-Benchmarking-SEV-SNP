#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------
# Variables
# -----------------------------------------------------------------

CONFIG=""
MOUNT="/mnt/dbdata"
OUT="./raw_results"
SIZE="16G"
RUNTIME=60
RAMP=10
IODEPTH=32
REPS=1
SEED=20262027
JOB_FILTER=""
SCRIPT_IDR="$(dirname "$(readlink -f "$0")")"

JOB_LIST=(
  "seqread_1m_qd32|read|1M|QD|"
  "seqwrite_1m_qd32|write|1M|QD|"
  "randread_4k_qd32|randread|4k|QD|"
  "randwrite_4k_qd32|randwrite|4k|QD|"
  "randrw70_4k_qd32|randrw|4k|QD|--rwmixread=70"
  "randread_4k_qd1|randread|4k|1|"
  "randwrite_4k_qd1|randwrite|4k|1|"
  "randwrite_4k_qd1_fsync|randwrite|4k|1|--fsync=1"
  "randread_4k_qd4|randread|4k|4|"
  "randwrite_4k_qd4|randwrite|4k|4|"
  "randwrite_4k_qd8|randwrite|4k|8|"
  "randwrite_4k_qd16|randwrite|4k|16|"
)

# -----------------------------------------------------------------
# Parsing
# -----------------------------------------------------------------

while (($#)); do
  case "$1" in
  --config)
    CONFIG="${2:?Missing value for --config}"
    shift 2
    ;;
  --mount)
    MOUNT="${2:?Missing value for --mount}"
    shift 2
    ;;
  --out)
    OUT="${2:?Missing value for --out}"
    shift 2
    ;;
  --size)
    SIZE="${2:?Missing value for --size}"
    shift 2
    ;;
  --runtime)
    RUNTIME="${2:?Missing value for --runtime}"
    shift 2
    ;;
  --ramp)
    RAMP="${2:?Missing value for --ramp}"
    shift 2
    ;;
  --repetitions)
    REPS="${2:?Missing value for --repetitions}"
    shift 2
    ;;
  --seed)
    SEED="${2:?Missing value for --seed}"
    shift 2
    ;;
  --jobs)
    JOB_FILTER="${2:?Missing value for --jobs}"
    shift 2
    ;;
  *)
    echo "ERROR: Unknow argument: $1" >&2
    exit 2
    ;;
  esac
done

case "$CONFIG" in
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

if [[ -z "$JOB_FILTER" ]]; then
  JOBS=("${JOB_LIST[@]}")
else
  JOBS=()
  IFS=',' read -ra WANTED <<<"$JOB_FILTER"
  for wanted in "${WANTED[@]}"; do
    for job in "${JOB_LIST[@]}"; do
      if [[ "${job%%|*}" == "$wanted" ]]; then
        JOBS+=("$job")
      fi
    done
  done
  if [[ ${#JOBS[@]} -ne ${#WANTED[@]} ]]; then
    echo "ERROR: Unknow job in --jobs"
    exit 2
  fi
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
CAMPAIGN="${OUT}/${TS}__fio__${CONFIG}__storage-baseline"
RUNS_DIR="$CAMPAIGN/runs"
LOG="$CAMPAIGN/run.log"
TESTFILE="$MOUNT/.fio_baseline_${CONFIG}.dat"
mkdir -p "$RUNS_DIR"

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

check_allocated() {
  local APPARENT ALLOCATED UNWRITTEN
  APPARENT="$(stat -c %s "$TESTFILE")"
  ALLOCATED=$(($(stat -c %b "$TESTFILE") * 512))
  if [[ $((ALLOCATED * 100 / APPARENT)) -lt 95 ]]; then
    die "Test file not fully allocated"
  fi
  UNWRITTEN="$(filefrag -v "$TESTFILE" | grep -c unwritten || true)"
  if [[ "$UNWRITTEN" -gt 0 ]]; then
    die "Testfile has unwrriten extends"
  fi
}

# -----------------------------------------------------------------
# Guards
# -----------------------------------------------------------------

command -v fio >/dev/null 2>&1 ||
  die "Fio not installed"

command -v python3 >/dev/null 2>&1 ||
  die "Pyhton not installed"

if ! mountpoint -q "$MOUNT"; then
  die "$MOUNT is not a mount point"
fi

SIZE_MB=$(($(numfmt --from=iec "$SIZE") / 1048576))
AVAILABLE_MB="$(df -BM --output=avail "$MOUNT" | tail -1 | tr -dc '0-9')"
if [[ ! -f "$TESTFILE" && "$AVAILABLE_MB" -lt $((SIZE_MB + 1024)) ]]; then
  die "Not enough free space"
fi

# -----------------------------------------------------------------
# Manifest
# -----------------------------------------------------------------

JOB_NAMES=()
for job in "${JOBS[@]}"; do
  JOB_NAMES+=("${job%%|*}")
done

python3 "$SCRIPT_IDR/fio_manifest.py" "$CAMPAIGN/manifest.json" \
  "$TS" \
  "$CONFIG" \
  "$MOUNT" \
  "$(findmnt -no SOURCE --first-only "$MOUNT")" \
  "$SIZE" \
  "$RUNTIME" \
  "$RAMP" \
  "$IODEPTH" \
  "$REPS" \
  "$SEED" \
  "${JOB_NAMES[@]}"

log "Manifest written"

# -----------------------------------------------------------------
# Testfile
# -----------------------------------------------------------------

if [[ -f "$TESTFILE" ]]; then
  log "Reusing test file"
else
  log "Writing test file, this takes sometime"
  fio --name=layout --filename="$TESTFILE" --size="$SIZE" --rw=write --bs=1M \
    --direct=1 --ioengine=libaio --iodepth=32 --fallocate=none \
    --output-format=json --output="$CAMPAIGN/layout.json" >/dev/null ||
    die "Creating test layout failed"
  sync
fi

check_allocated

# -----------------------------------------------------------------
# Run
# -----------------------------------------------------------------

FAILED=0

for rep in $(seq 1 "$REPS"); do
  for job in "${JOBS[@]}"; do
    IFS='|' read -r name rw bs qd extra <<<"$job"
    if [[ "$qd" == "QD" ]]; then
      qd="$IODEPTH"
    fi
    run_dir="$RUNS_DIR/$(printf '%s__r%02d' "$name" "$rep")"
    mkdir -p "$run_dir"
    cmd=(
      fio
      --name="$name"
      --filename="$TESTFILE"
      --size="$SIZE"
      --rw="$rw"
      --bs="$bs"
      --iodepth="$qd"
      --numjobs=1
      --direct=1
      --ioengine=libaio
      --runtime="$RUNTIME"
      --time_based
      --ramp_time="$RAMP"
      --randrepeat=1
      --randseed="$SEED"
      --group_reporting
      --output-format=json
    )
    if [[ -n "$extra" ]]; then
      cmd+=("$extra")
    fi

    log "Rep $rep/$REPS $name"
    echo "${cmd[*]}" >"$run_dir/command.txt"
    if ! "${cmd[@]}" --output="$run_dir/fio.json" >"$run_dir/fio.stdout" 2>"$run_dir/fio.stderr"; then
      log "Fio failed for $name rep $rep"
      FAILED=$((FAILED + 1))
    fi
    sleep 5
  done
done

# -----------------------------------------------------------------
# Summary
# -----------------------------------------------------------------

python3 "$SCRIPT_IDR/fio_summary.py" "$RUNS_DIR" "$CAMPAIGN/summary.csv" \
  "$CAMPAIGN/summary.txt" "$CONFIG"

log "Results in $CAMPAIGN"

if [[ "$FAILED" -gt 0 ]]; then
  die "$FAILED runs"
fi

log "Block size done"
