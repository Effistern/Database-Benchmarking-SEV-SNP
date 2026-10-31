#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------
# Variables
# -----------------------------------------------------------------

DISKNAME="dbdata"
DEVICE=""
MOUNTPOINT="/mnt/dbdata"
READHEAD_KB=128
SCHEDULER="none"
THP="never"

FS_LABEL="dbdata"
STATE_DIR="/var/lib/db-benchmark"
LOG="/var/log/prepare_vm.log"

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

CHANGES=()
noted() {
  CHANGES+=("$1")
  log "$1"
}

log "Preparing vm"

# -----------------------------------------------------------------
# Disabling background timers and services
# -----------------------------------------------------------------

UNITS=(
  unattended-upgrades.service
  apt-daily.timer
  apt-daily-upgrade.timer
  packagekit.service
  update-notifier-download.timer
  update-notifier-motd.timer
  snapd.refresh.timer
  snapd.snap-repair.timer
  fstrim.timer
  e2scrub_all.timer
  man-db.timer
  motd-news.timer
  sysstat-collect.timer
  sysstat-summary.timer
)

log "Disabling background timers and services"
for unit in "${UNITS[@]}"; do
  if systemctl cat "$unit" >/dev/null 2>&1; then
    if systemctl is-enabled "$unit" >/dev/null 2>&1 || systemctl is-active "$unit" >/dev/null 2>&1; then
      systemctl disable --now "$unit" ||
        log "Could not disable $unit"
      noted "disabled $unit"
    fi
  fi
done

if command -v snap >/dev/null 2>&1; then
  snap refresh --hold ||
    log "Snap refresh --hold is not supported here"
fi

# -----------------------------------------------------------------
# Disabling background timers and services
# -----------------------------------------------------------------

PACKAGES=(sysstat fio numactl curl git python3 sysbench)

MISSING=()

for package in "${PACKAGES[@]}"; do
  dpkg-query -W -f='${STATUS}' "$package" 2>/dev/null | grep -q "Installed" ||
    MISSING+=("$package")
done
if [[ ${#MISSING[@]} -eq 0 ]]; then
  log "All required packages installed"
else
  log "Installing: ${MISSING[*]}"
  env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${MISSING[@]}"
  noted "Installed ${MISSING[*]}"
fi

if [[ -f /etc/default/sysstat ]]; then
  sed -i 's/^ENABLED=.*/ENABLED="false"/' /etc/default/sysstat
fi

# -----------------------------------------------------------------
# Data disk
# -----------------------------------------------------------------

BY_ID="/dev/disk/by-id/google-${DISKNAME}"
MOUNT_OPTS="defaults,noatime"

locate_device() {
  if [[ -e "$BY_ID" ]]; then
    log "Detected data disk: $BY_ID"
    DEVICE="$BY_ID"
  else
    die "No data disk found at $BY_ID"
  fi
  DEVICE="$(readlink -f "$DEVICE")"
}

guard_device() {
  if [[ ! -b "$DEVICE" ]]; then
    die "$DEVICE is not a block device"
  fi
  local other
  other="$(lsblk -nro MOUNTPOINT "$DEVICE" | grep -v '^$' | grep -vxF "$MOUNTPOINT" || true)"
  if [[ ! -z "$other" ]]; then
    die " $DEVICE is already in use"
  fi
}

format_if_blank() {
  local fstype pttype
  fstype="$(blkid -p -o value -s TYPE "$DEVICE" || true)"
  pttype="$(blkid -p -o value -s PTTYPE "$DEVICE" || true)"

  if [[ "$fstype" == ext4 ]]; then
    log "$DEVICE already has an ext4 filesystem, mounting as-is"
    return 0
  fi
  log "$DEVICE has no filesystem -> Formatting"
  mkfs.ext4 -F -L "$FS_LABEL" -E nodiscard -m 0 "$DEVICE"
  noted "formatted $DEVICE as ext4"
}

update_fstab() {
  local uuid
  uuid="$(blkid -p -o value -s UUID "$DEVICE")"
  if grep -qs "UUID=$uuid[[:space:]]" /etc/fstab; then
    log "Fstab already has entry for disk"
    return 0
  fi

  cp -a /etc/fstab "/etc/fstab.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  awk -v mp="$MOUNTPOINT" '/^[[:space:]]*#/ {print; next} $2 != mp {print}' /etc/fstab >/etc/fstab.new
  printf 'UUID=%s %s ext4 %s,nofail 0 2\n' "$uuid" "$MOUNTPOINT" "$MOUNT_OPTS" >>/etc/fstab.new
  mv /etc/fstab.new /etc/fstab
  systemctl daemon-reload >/dev/null 2>&1 || true
  noted "added /etc/fstab entry"
}

normalise_read_ahead() {
  local base q
  base="$(lsblk -no PKNAME "$DEVICE" | head -1)"
  base="${base:-$(basename "$DEVICE")}"
  q="/sys/block/$base/queue"
  if [[ ! -d "$q" ]]; then
    log "Skipping normalisation, not found"
    return 0
  fi
  echo "$READHEAD_KB" >"$q/read_ahead_kb"
  noted "Set read_ahead"

  if grep -qw "$SCHEDULER" "$q/scheduler"; then
    echo "$SCHEDULER" >"$q/scheduler"
    noted "Set I/O scheduler"
  else
    log "Scheduler not available"
  fi
}

prepare_disk() {
  locate_device
  guard_device
  local current

  current="$(findmnt -no SOURCE --mountpoint "$MOUNTPOINT" || true)"
  if [[ "$current" == "$DEVICE" ]]; then
    log "$DEVICE already mounted"
  elif [[ -n "$current" ]]; then
    die "$MOUNTPOINT is already in use"
  else
    format_if_blank
    mkdir -p "$MOUNTPOINT"
    mount -o "$MOUNT_OPTS" "$DEVICE" "$MOUNTPOINT"
    chmod 0755 "$MOUNTPOINT"
    noted "Mounted $DEVICE at $MOUNTPOINT"
  fi
  update_fstab
  normalise_read_ahead
}

prepare_disk

# -----------------------------------------------------------------
# Making memory similar
# -----------------------------------------------------------------

if [[ -w /sys/kernel/mm/transparent_hugepage/enabled ]]; then
  bash -c "echo $THP > /sys/kernel/mm/transparent_hugepage/enabled"
  if [[ -e /sys/kernel/mm/transparent_hugepage/defrag ]]; then
    bash -c "echo $THP > /sys/kernel/mm/transparent_hugepage/defrag"
  fi
  noted "Set transparent_hugepage tp $THP"
else
  log "Could not set transparent_hugepage"
fi

# -----------------------------------------------------------------
# Writing down
# -----------------------------------------------------------------

python3 "$(dirname "$(readlink -f "$0")")/prepare_state.py" \
  "$STATE_DIR/prepare_state.json" \
  "$MOUNTPOINT" \
  "${DEVICE:-}" \
  "$THP" \
  "$READHEAD_KB" \
  "$SCHEDULER" \
  "$DISKNAME" \
  "${CHANGES[@]:-}"

log "State written"
