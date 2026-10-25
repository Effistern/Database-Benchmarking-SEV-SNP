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
REPS=1
SEED=20262027
BLOCK_SIZES="4k,16k,64k,256k,1M"
PATTERNS="randread,randwrite"
SCRIPT_IDR="$(dirname "$(readlink -f "$0")")"

# -----------------------------------------------------------------
# Parsing
# -----------------------------------------------------------------

while (($#)); do
  case "$1" in
  --config)
    CONFIG="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --mount)
    MOUNT="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --out)
    OUT="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --size)
    SIZE="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --runtime)
    RUNTIME="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --ramp)
    RAMP="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --repetitions)
    REPS="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --seed)
    SEED="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --block-sizes)
    BLOCK_SIZES="${2:?Missing value for --heap-gb}"
    shift 2
    ;;
  --pattern)
    PATTERNS="${2:?Missing value for --heap-gb}"
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

TS="$(date -u +%Y%m%dT%H%M%SZ)"
CAMPAIGN="${OUT}/${TS}__iosize__${CONFIG}__blocksize-sweep"
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

IFS="," read -ra SIZES <<<"$BLOCK_SIZES"
IFS="," read -ra RWS <<<"$PATTERNS"
TOTAL=$((${#SIZES[@]} * ${#RWS[@]} * REPS))

log "Block size check. Config: ${CONFIG}, sizes: $BLOCK_SIZES, patterns: $PATTERNS"
log "${TOTAL} runs"

# -----------------------------------------------------------------
# Test file
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

APPARENT="$(stat -c %s "$TESTFILE")"
ALLOCATED=$(($(stat -c %b "$TESTFILE") * 512))
if [[ $((ALLOCATED * 100 / APPARENT)) -lt 95 ]]; then
  die "Test file not fully allocated"
fi

# -----------------------------------------------------------------
# Manifest
# -----------------------------------------------------------------

python3 "$SCRIPT_IDR/iosize_manifest.py" "$CAMPAIGN/manifest.json" \
  "$TS" \
  "$CONFIG" \
  "$MOUNT" \
  "$(findmnt -no SOURCE --first-only "$MOUNT")" \
  "$BLOCK_SIZES" \
  "$PATTERNS" \
  "$SIZE" \
  "$RAMP" \
  "$REPS" \
  "$SEED"

log "Manifest written"

# -----------------------------------------------------------------
# Sweep
# -----------------------------------------------------------------

FAILED=0
DONE=0

for rep in $(seq 1 "$REPS"); do
  for rw in "${RWS[@]}"; do
    for bs in "${SIZES[@]}"; do
      name="${rw}_${bs}_qd1"
      run_dir="$RUNS_DIR/$(printf '%s__r%02d' "$name" "$rep")"
      mkdir -p "$run_dir"

      cmd=(
        fio
        --name="$name"
        --filename="$TESTFILE"
        --size="$SIZE"
        --rw="$rw"
        --bs="$bs"
        --iodepth=1
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

      DONE=$((DONE + 1))
      log "[$DONE/$TOTAL] $name rep $rep"
      echo "${cmd[*]}" >"$run_dir/command.txt"
      if ! "${cmd[@]}" --output="$run_dir/fio.json" >"$run_dir/fio.stdout" 2>"$run_dir/fio.stderr"; then
        log "fio failed for $name rep $rep"
        FAILED=$((FAILED + 1))
      fi
      sleep 5
    done
  done
done

# -----------------------------------------------------------------
# Summary
# -----------------------------------------------------------------

python3 "$SCRIPT_IDR/iosize_summary.py" "$RUNS_DIR" "$CAMPAIGN/summary.csv" \
  "$CAMPAIGN/summary.txt" "$CONFIG"

log "Results in $CAMPAIGN"

if [[ "$FAILED" -gt 0 ]]; then
  die "$FAILED runs"
fi

log "Block size done"
