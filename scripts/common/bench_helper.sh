#!/bin/bash

BENCH_HELPER_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
OS_SUMMARISER="${BENCH_HELPER_DIR}/summarise_os_metrics.py"
PID_CHECK_SECONDS=10

data_disk_device() {
  local source
  source="$(findmnt -no SOURCE --first-only "$1" 2>/dev/null || true)"
  if [[ -z "$source" ]]; then
    return 1
  fi
  basename "$source"
}

largest_process_in_unit() {
  local unit="$1" cgroup procs_file pid rss
  local best_pid="" best_rss=-1

  cgroup="$(systemctl show "$unit" -p ControlGroup --value 2>/dev/null || true)"
  if [[ -z "$cgroup" ]]; then
    return 1
  fi

  procs_file="/sys/fs/cgroup${cgroup}/cgroup.procs"
  if [[ ! -r "$procs_file" ]]; then
    procs_file="/sys/fs/cgroup/systemd${cgroup}/cgroup.procs"
  fi

  if [[ ! -r "$procs_file" ]]; then
    return 1
  fi

  while read -r pid; do
    rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    if [[ -z "$rss" ]]; then
      continue
    fi
    if ((rss > best_rss)); then
      best_rss="$rss"
      best_pid="$pid"
    fi
  done <"$procs_file"
  if [[ -z "$best_pid" ]]; then
    return 1
  fi
  echo "$best_pid"
}

cpu_ticks() {
  local stat after_name
  local -a fields
  stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  after_name="${stat##*) }"
  read -r -a fields <<<"$after_name"
  echo $((fields[11] + fields[12] + fields[13] + fields[14]))
}

assert_process_is_working() {
  local pid="$1" label="$2"
  shift 2
  local before now second
  before="$(cpu_ticks "$pid")" ||
    die "$label: Process $pid does not exist"
  "$@" || true
  for ((second = 1; second <= PID_CHECK_SECONDS; second++)); do
    sleep 1
    now="$(cpu_ticks "$pid")" ||
      die "Process exited during PID check"
    if ((now > before)); then
      log "PID verified"
      return 0
    fi
  done
  die "PID used no CPU, discarding the run"
}

summarise_run_os_metrics() {
  local run_dir="$1" device="$2"
  local summary="$run_dir/os_summary.json"

  if ! python3 "$OS_SUMMARISER" "$run_dir/os_metrics" --device "$device" \
    >"$summary" 2>"$run_dir/os_summary.err"; then
    log "OS summary failed"
    echo '{}' >"$summary"
    return 0
  fi
}
