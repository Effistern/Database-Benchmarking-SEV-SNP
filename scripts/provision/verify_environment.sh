#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------
# Variables
# -----------------------------------------------------------------

CONFIG=""
OUT_DIR=""
EXPECT_VCPU=""
EXPECT_MEM_GB=""
MEM_TOLERANCE=5
DATA_MOUNT="/mnt/dbdata"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
HOST="$(hostname -s)"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# -----------------------------------------------------------------
# Parsing
# -----------------------------------------------------------------

while (($#)); do
  case "$1" in
  --config)
    CONFIG="${2:?Missing value for --config}"
    shift 2
    ;;
  --out)
    OUT_DIR="${2:?Missing value for --out}"
    shift 2
    ;;
  --vcpu)
    EXPECT_VCPU="${2:?Missing value for --vcpu}"
    shift 2
    ;;
  --mem)
    EXPECT_MEM_GB="${2:?Missing value for --mem}"
    shift 2
    ;;
  *)
    echo "ERROR: Unknown argument: $1" >&2
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

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="./env_check/${HOST}_${TS}"
fi

RAW_DIR="$OUT_DIR/raw"
FACTS="$OUT_DIR/facts.tsv"
LOG="$OUT_DIR/verify.log"

mkdir -p "$RAW_DIR"
rm -f "$FACTS"

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

fact() {
  local value
  value="$(printf '%s' "$2" | tr '\n\t' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
  printf '%s\t%s\n' "$1" "$value" >>"$FACTS"
}

warn() {
  WARNING+=("$1")
  log "WARNING: $1"
}

fail() {
  FAILURES+=("$1")
  log "FAIL: $1"
}

lscpu_value() {
  awk -F': +' -v key="$1" '{ sub(/^ +/, "") } $1 == key { print $2; exit }' "$RAW_DIR/lscpu.txt"
}

base_device() {
  local parent
  parent="$(lsblk -no PKNAME "$1" | head -1)"
  if [[ -z "$parent" ]]; then
    parent="$(basename "$1")"
  fi
  echo "$parent"
}

md_get() {
  curl -s -f -m 3 -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/$1" || echo "unavailable"
}

# -----------------------------------------------------------------
# Guards
# -----------------------------------------------------------------

if [[ "$(id -u)" -ne 0 ]]; then
  die "Must run as root"
fi

command -v python3 >/dev/null 2>&1 ||
  die "python3 not installed"

log "Verifying environtment, config $CONFIG, output $OUT_DIR"

# -----------------------------------------------------------------
# Identity of the system
# -----------------------------------------------------------------

FAILURES=()
WARNING=()

fact "capture.timestamp_utc" "$TS"
fact "capture.hostname" "$(hostname -f)"
fact "capture.script_version" "1"
fact "claim.config" "$CONFIG"

# -----------------------------------------------------------------
# GCE metadata
# -----------------------------------------------------------------

fact "gce.machine_type" "$(md_get machine-type | awk -F/ '{print $NF}')"
fact "gce.cpu_platform" "$(md_get cpu-platform)"
fact "gce.zone" "$(md_get zone | awk -F/ '{print $NF}')"
fact "gce.instance_id" "$(md_get id)"
fact "gce.instance_name" "$(md_get name)"
fact "gce.image" "$(md_get image | awk -F/ '{print $NF}')"
fact "gce.description" "$(md_get description)"
fact "gce.maintenance_event" "$(md_get maintenance-event)"
fact "gce.automatic_restart" "$(md_get scheduling/automatic-restart)"
fact "gce.on_host_maintenance" "$(md_get scheduling/on-host-maintenance)"
fact "gce.preemptible" "$(md_get scheduling/preemptible)"

# -----------------------------------------------------------------
# Mem encryption
# -----------------------------------------------------------------

dmesg >"$RAW_DIR/dmesg.txt" 2>/dev/null || true

if [[ -s "$RAW_DIR/dmesg.txt" ]]; then
  KERNEL_LOG=true
else
  warn "dmesg not readable"
  KERNEL_LOG=false
fi

DMESG_SEV="$(grep -i "Memory Encryption Features active" "$RAW_DIR/dmesg.txt" | tail -1 || true)"
grep -iE "sev|sme|memory encryption|ccp|psp" "$RAW_DIR/dmesg.txt" >"$RAW_DIR/dmesg_sev.txt" || true

fact "sev.kernel_log_readable" "$KERNEL_LOG"
fact "sev.dmesg_line" "${DMESG_SEV:-none}"

if ! mountpoint -q /sys/kernel/debug; then
  mount -t debugfs none /sys/kernel/debug || true
fi

SEV_STATUS="$(cat /sys/kernel/debug/x86/sev_status 2>/dev/null | tr -d '[:space:]' || true)"
fact "sev.sev_status_raw" "${SEV_STATUS:-unavailable}"

BIT_SEV=0
BIT_ES=0
BIT_SNP=0

if grep -qiw "SEV" <<<"$DMESG_SEV"; then
  BIT_SEV=1
fi
if grep -qiw "SEV-ES" <<<"$DMESG_SEV"; then
  BIT_ES=1
fi
if grep -qiw "SEV-SNP" <<<"$DMESG_SEV"; then
  BIT_SNP=1
fi

if [[ "$BIT_SNP" -eq 1 && "$BIT_ES" -eq 1 ]]; then
  DETECTED="sev-snp"
elif [[ "$BIT_SEV" -eq 1 ]]; then
  DETECTED="sev"
elif [[ "$KERNEL_LOG" == true || -n "$SEV_STATUS" ]]; then
  DETECTED="none"
else
  DETECTED="unknown"
fi

fact "sev.detected" "$DETECTED"
fact "sev.bit_sev" "$BIT_SEV"
fact "sev.bit_sev_es" "$BIT_ES"
fact "sev.bit_sev_snp" "$BIT_SNP"

case "$CONFIG:$DETECTED" in
none:none | sev:sev | snp:sev-snp)
  log "Claimed configs matched"
  ;;
*:unknown)
  fail "Encryption state could not be determined"
  ;;
*)
  fail "VM mislabled"
  ;;
esac

# -----------------------------------------------------------------
# SWIOTLB bounce buffer
# -----------------------------------------------------------------

grep -i "swiotlb\|bounce" "$RAW_DIR/dmesg.txt" >"$RAW_DIR/swiotlb.txt" || true
SWIOTLB_LINE="$(grep -i "swiotlb" "$RAW_DIR/dmesg.txt" | head -3 | tr '\n' ' ' || true)"

SWIOTLB_NSLABS="$(cat /sys/kernel/debug/swiotlb/io_tlb_nslabs 2>/dev/null | tr -dc '0-9' || true)"

fact "dma.swiotlb_dmesg" "${SWIOTLB_LINE:-none}"
fact "dma.swiotlb_nslabs" "${SWIOTLB_NSLABS:-unavailable}"

if [[ -n "$SWIOTLB_NSLABS" ]]; then
  fact "dma.swiotlb_mb" "$((SWIOTLB_NSLABS / 512))"
  fact "dma.swiotlb_source" "io_tlb_nslabs"
else
  SWIOTLB_MB="$(grep -oE '[0-9]+ *MB' <<<"$SWIOTLB_LINE" | tail -1 | tr -dc '0-9' || true)"
  fact "dma.swiotlb_mb" "${SWIOTLB_MB:-unknown}"
  fact "dma.swiotlb_source" "dmesg"
fi

fact "dma.swiotlb_cmdline" "$(grep -oE 'swiotlb=[^ ]*' /proc/cmdline || echo unset)"
fact "disk.nvme_namespaces" "$(lsblk -dno NAME | grep -c '^nvme' || true)"

# -----------------------------------------------------------------
# CPU
# -----------------------------------------------------------------

lscpu >"$RAW_DIR/lscpu.txt"
lscpu -p >"$RAW_DIR/lscpu_parse.txt"
cat /proc/cpuinfo >"$RAW_DIR/cpuinfo.txt"
numactl --hardware >"$RAW_DIR/numactl.txt" 2>&1 || true

VCPU="$(nproc)"
TPC="$(lscpu_value "Thread(s) per core")"
NODES="$(ls -d /sys/devices/system/node/node[0-9]* | wc -l)"

fact "cpu.model" "$(lscpu_value "Model name")"
fact "cpu.vendor" "$(lscpu_value "Vendor ID")"
fact "cpu.family" "$(lscpu_value "CPU family")"
fact "cpu.model_id" "$(lscpu_value "Model")"
fact "cpu.stepping" "$(lscpu_value "Stepping")"
fact "cpu.microcode" "$(awk -F': +' '/^microcode/ {print $2; exit}' "$RAW_DIR/cpuinfo.txt")"
fact "cpu.vcpus" "$VCPU"
fact "cpu.threads_per_core" "$TPC"
fact "cpu.flags" "$(awk -F': ' '/^flags/ {print$2; exit}' "$RAW_DIR/cpuinfo.txt" | tr ' ' ',')"
fact "cpu.numa_nodes" "$NODES"
fact "cpu.governor" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unavailable)"

if [[ -n "$EXPECT_VCPU" && "$VCPU" != "$EXPECT_VCPU" ]]; then
  warn "vCPU count is $VCPU, expected $EXPECT_VCPU"
fi

if [[ "$TPC" != "1" ]]; then
  warn "SMT is enabled"
fi

if [[ "$NODES" -gt 1 ]]; then
  warn "More than one NUMA node"
fi

# -----------------------------------------------------------------
# Memory
# -----------------------------------------------------------------

cat /proc/meminfo >"$RAW_DIR/meminfo.txt"

MEM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
MEM_MB=$((MEM_KB / 1024))
SWAP_KB="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"

fact "mem.total_kb" "$MEM_KB"
fact "mem.total_mb" "$MEM_MB"
fact "mem.hugepages" "$(awk '/^HugePages_Total:/ {print $2}' /proc/meminfo)"
fact "mem.thp" "$(cat /sys/kernel/mm/transparent_hugepage/enabled)"
fact "mem.swap_total_kb" "$SWAP_KB"

if [[ "$SWAP_KB" -gt 0 ]]; then
  warn "Swap is enabled"
fi

if [[ -n "$EXPECT_MEM_GB" ]]; then
  EXPECT_MB=$((EXPECT_MEM_GB * 1024))
  DELTA=$((MEM_MB - EXPECT_MB))
  if [[ "$DELTA" -lt 0 ]]; then
    DELTA=$((-DELTA))
  fi
  PCT=$((DELTA * 100 / EXPECT_MB))
  fact "mem.deviation_pct" "$PCT"
  if [[ "$PCT" -gt "$MEM_TOLERANCE" ]]; then
    warn "MemTotal deviates ${PCT}%"
  fi
fi

# -----------------------------------------------------------------
# OS
# -----------------------------------------------------------------

uname -a >"$RAW_DIR/uname.txt"
cat /etc/os-release >"$RAW_DIR/os_release.txt"
dpkg-query -W -f='${Package}\t${Version}\n' >"$RAW_DIR/dpkg_list.txt"

fact "os.kernel" "$(uname -r)"
fact "os.arch" "$(uname -m)"
fact "os.pretty_name" "$(awk -F'"' '/^PRETTY_NAME=/ {print $2}' /etc/os-release)"
fact "os.version_id" "$(awk -F'"' '/^VERSION_ID=/ {print $2}' /etc/os-release)"
fact "os.uptime_s" "$(awk '{print int($1)}' /proc/uptime)"
fact "os.boot_cmdline" "$(cat /proc/cmdline)"
fact "os.package_count" "$(wc -l <"$RAW_DIR/dpkg_list.txt")"

# -----------------------------------------------------------------
# Storage
# -----------------------------------------------------------------

lsblk -o NAME,SIZE,TYPE,ROTA,SCHED,MOUNTPOINT,FSTYPe >"$RAW_DIR/lsblk.txt"
findmnt -A -o TARGET,SOURCE,FSTYPE,OPTIONS >"$RAW_DIR/mounts.txt"
df -h >"$RAW_DIR/df.txt" || true

ROOT_DEV="$(findmnt -no SOURCE /)"
ROOT_BASE="$(base_device "$ROOT_DEV")"
DATA_DEV="$(findmnt -no SOURCE "$DATA_MOUNT" || true)"

fact "disk.root_device" "$ROOT_DEV"
fact "disk.root_fstype" "$(findmnt -no FSTYPE /)"
fact "disk.root_size" "$(df -BG --output=size / | tail -1 | tr -d ' G')"
fact "disk.root_mount_options" "$(findmnt -no OPTIONS /)"
fact "disk.scheduler" "$(cat "/sys/block/$ROOT_BASE/queue/scheduler")"
fact "disk.rotational" "$(cat "/sys/block/$ROOT_BASE/queue/rotational")"
fact "disk.readahead_kb" "$(cat "/sys/block/$ROOT_BASE/queue/read_ahead_kb")"
fact "datadisk.mount_point" "$DATA_MOUNT"

if [[ -n "$DATA_DEV" ]]; then
  DATA_BASE="$(base_device "$DATA_DEV")"
  fact "datadisk.device" "$DATA_DEV"
  fact "datadisk.fstype" "$(findmnt -no FSTYPE "$DATA_MOUNT")"
  fact "datadisk.options" "$(findmnt -no OPTIONS "$DATA_MOUNT")"
  fact "datadisk.size" "$(lsblk -ndo SIZE "$DATA_DEV" | tr -d ' ')"
  fact "datadisk.avail" "$(df -h --output=avail "$DATA_MOUNT" | tail -1 | tr -d ' ')"
  fact "datadisk.readahead_kb" "$(cat "/sys/block/$DATA_BASE/queue/read_ahead_kb")"
  fact "datadisk.schedule" "$(cat "/sys/block/$DATA_BASE/queue/scheduler")"
  fact "datadisk.rotational" "$(cat "/sys/block/$DATA_BASE/queue/rotational")"
else
  warn "Nothing mounted  at $DATA_MOUNT"
  fact "datadisk.device" "not_mounted"
fi

# -----------------------------------------------------------------
# PMU
# -----------------------------------------------------------------

PERF_INSTALLED=false
PMU_USABLE=false

if command -v perf >/dev/null 2>&1; then
  PERF_INSTALLED=true
  if perf stat -e instructions,cycles -- true >"$RAW_DIR/perf_probe.txt" 2>&1; then
    if ! grep -qiE "not supported|<not counted>|no permission" "$RAW_DIR/perf_probe.txt"; then
      PMU_USABLE=true
    fi
  fi
fi

fact "pmu.perf_event_paranoid" "$(cat /proc/sys/kernel/perf_event_paranoid)"
fact "pmu.perf_installed" "$PERF_INSTALLED"
fact "pmu.counters_usable" "$PMU_USABLE"

# -----------------------------------------------------------------
# Background monitoring
# -----------------------------------------------------------------

fact "noise.google_ops_agent" "$(systemctl is-active google-cloud-ops-agent | head -1)"

# -----------------------------------------------------------------
# Writing down
# -----------------------------------------------------------------

for warning in "${WARNING[@]}"; do
  fact "warning[]" "$warning"
done

for failure in "${FAILURES[@]}"; do
  fact "failure[]" "$failure"
done

VERDICT="pass"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  VERDICT="fail"
fi

fact "result.warning_count" "${#WARNING[@]}"
fact "result.failure_count" "${#FAILURES[@]}"
fact "result.verdict" "$VERDICT"

python3 "$SCRIPT_DIR/write_environment.py" "$FACTS" "$OUT_DIR/environment.json"
rm -f "$FACTS"

if [[ "$VERDICT" == "fail" ]]; then
  die "Dont continue. There are failures, check why"
fi

log "No failures, can proceed"
