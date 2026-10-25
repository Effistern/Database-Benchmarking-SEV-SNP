#!/usr/bin/env python3
import datetime
import json
import subprocess
import sys

(
    output_path,
    config,
    shared_buffers_gb,
    eff_buffers,
    work_mem_mb,
    eff_work_mem,
    eff_eff_cache,
    sync_commit,
    eff_sync,
    pg_data,
    dev_data,
    bind_ip,
    act_aff,
    use_affinity,
    mem_mb
 ) = sys.argv[1:]

def sh(cmd):
    try:
        return subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except subprocess.CalledProcessError as e:
        return "unavailable"

data = {
    "configured_at_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S"),
    "config": config,
    "pg_version": sh("sudo -u postgres psql -t -A-c 'SHOW server_version'"),
    "requested_shared_buffers_gb": float(shared_buffers_gb),
    "effective_shared_buffers_gb": eff_buffers,
    "requested_work_mem_mb": int(work_mem_mb),
    "effective_work_mem": eff_work_mem,
    "effective_cache_size": eff_eff_cache,
    "requested_synchronous_commit": sync_commit,
    "effective_synchronous_commit": eff_sync,
    "datapath": pg_data,
    "data_device": dev_data,
    "bind_ip": bind_ip,
    "cpu_affinity": act_aff,
    "affinity_enabled": use_affinity.lower() == "true",
    "mem_total_mb": int(mem_mb),
    "lscpu_topology": sh("lscpu -p=CPU,CORE,SOCKET | grep -v '^#' | tr '\\n' ';'")
}

with open(output_path, "w", encoding="utf-8") as file:
    json.dump(data, file, indent=2)