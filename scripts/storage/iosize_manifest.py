import datetime
import json
import platform
import subprocess
import sys

(manifest_path, ts, config, mount, device, block_size, patterns, size,
 ramp, reps, seed) = sys.argv[1:]


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()


with open(manifest_path, "w") as file:
    json.dump({
        "campaign_id": f"{ts}__iosize__{config}__blocksize-sweep",
        "timestamp_utc": ts,
        "config": config,
        "tool": "fio",
        "hostname": platform.node(),
        "kernel": platform.release(),
        "mount_point": mount,
        "device": device,
        "mount_options": sh(f"findmnt -no OPTIONS {mount}"),
        "parameters": {
            "block_size": block_size.split(","),
            "patterns": patterns.split(","),
            "iodepth": 1,
            "file_size": size,
            "ramp_s": int(ramp),
            "repetitions": int(reps),
            "randseed": int(seed),
            "direct": 1,
            "ioengine": "libaio"
        },
        "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }, file, indent=2)
