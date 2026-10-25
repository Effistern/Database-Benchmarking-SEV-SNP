import datetime
import json
import subprocess
import sys
import platform

(manifest_path, ts, config, mount, device, size, runtime,
 ramp, iodepth, reps, seed, *jobs) = sys.argv[1:]


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()


with open(manifest_path, 'w') as file:
    json.dump({
        "campaign_id": f"{ts}__fio__{config}__storage-baseline",
        "timestamp_utc": ts,
        "config": config,
        "hostname": platform.node(),
        "tool": "fio",
        "kernel": platform.release(),
        "mount_point": mount,
        "device": device,
        "mount_options": sh(f"findmnt -no OPTIONS {mount}"),
        "device_size": sh(f"lsblk -ndo SIZE {device}"),
        "jobs": jobs,
        "parameters": {
            "size": size,
            "runtime": int(runtime),
            "ramp_s": int(ramp),
            "iodepth_qd32_jobs": int(iodepth),
            "repetitions": int(reps),
            "randseed": int(seed),
            "direct": 1,
            "ioengine": "libaio"
        },
        "swiotlb_mb": sh("cat /sys/kernel/debug/swiotlb/io_tlb_nslabs 2>/dev/null"),
        "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }, file, indent=2)
