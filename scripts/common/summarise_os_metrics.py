#!/usr/bin/env python3
"""
Usage: python summarise_os_metrics.py <run_dir>/os_metrics [--device sdb] [--skip 10]
"""
import argparse
import json
import os
import re
import statistics
import sys


def _mean(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.mean(xs), 3) if xs else None


def parse_vmstat(path, skip):
    out = {k: [] for k in ("bi", "bo", "in", "cs", "us", "sy", "id", "wa", "st")}
    if not os.path.isfile(path):
        return out
    idx = None
    for line in open(path, errors="replace"):
        fields = line.split()
        if not fields:
            continue
        if fields[0] == "r" and "cs" in fields:
            idx = {name: i for i, name in enumerate(fields)}
            continue
        if idx is None or not fields[0].isdigit():
            continue
        for k in out:
            i = idx.get(k)
            if i is not None and i < len(fields):
                try:
                    out[k].append(float(fields[i]))
                except ValueError:
                    pass
    return {k: v[skip:] for k, v in out.items()}


def parse_iostat(path, device, skip):
    cols, rows = None, []
    if not os.path.isfile(path):
        return rows, None
    for line in open(path, errors="replace"):
        fields = line.split()
        if not fields:
            continue
        if fields[0] == "Device":
            cols = {name: i for i, name in enumerate(fields)}
            continue
        if cols is None or fields[0] != device:
            continue
        rec = {}
        for name in ("r/s", "rkB/s", "w/s", "wkB/s", "r_await", "w_await", "aqu-sz", "%util"):
            i = cols.get(name)
            if i is not None and i < len(fields):
                try:
                    rec[name] = float(fields[i])
                except ValueError:
                    pass
        rows.append(rec)
    return rows[skip:], cols


def parse_pidstat(path, skip):
    column = ("%CPU", "RSS", "majflt/s", "%wait")
    per_sample = {}
    process_per_sample = {}
    if not os.path.isfile(path):
        return {k: [] for k in column}, 0
    idx = None
    for line in open(path, errors="replace"):
        if line.startswith("#"):
            fields = line.lsplit("#").split()
            idx = {name: i for i, name in enumerate(fields)}
            continue
        fields = line.split()
        if idx is None or len(fields) < 5 or not re.match(r"^\d\d:\d\d:\d\d$", fields[0]):
            continue
        timestamp = fields[0]
        sample = per_sample.setdefault(timestamp, {k: 0.0 for k in column})
        process_per_sample[timestamp] = process_per_sample.get(timestamp, 0) + 1
        for k in column:
            i = idx.get(k)
            if i is not None and i < len(fields):
                try:
                    sample[k] += float(fields[i])
                except ValueError:
                    pass
    out = {k: [sample[k] for sample in per_sample.values()] for k in column}
    max_processes = max(process_per_sample.values(), default=0)
    return {k: v[skip:] for k, v in out.items()}, max_processes


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    ap.add_argument("dir")
    ap.add_argument("--device", default="sdb")
    ap.add_argument("--device-iops-ceiling", type=float, default=10800)
    ap.add_argument("--skip", type=int, default=10)
    args = ap.parse_args()

    dir = args.dir
    vmstat = parse_vmstat(os.path.join(dir, "vmstat.txt"), args.skip)
    iostat = parse_iostat(os.path.join(dir, "iostat.txt"), args.device, args.skip)
    pid, db_processes = {}, 0
    for f in os.listdir(dir) if os.path.isdir(dir) else []:
        if f.startswith("pidstat_"):
            pid, db_processes = parse_pidstat(os.path.join(dir, f), args.skip)
            break
    n = len(vmstat.get("cs", []))
    if n == 0 and not iostat:
        print("No usable samples found")
        return 1

    reads_per_s = [r.get("r/s") for r in iostat if "r/s" in r]
    rkb_per_s = [r.get("rkB/s") for r in iostat if "rkB/s" in r]

    summary = {
        "samples": n,
        "sample_interval_s": 1,
        "skipped_samples": args.skip,
        "device": args.device,
        "device_iops_ceiling": args.device_iops_ceiling,
        "disk_iops_share_of_ceiling": None,

        "cpu_user_pct": _mean(vmstat.get("us")),
        "cpu_system_pct": _mean(vmstat.get("sy")),
        "cpu_idle_pct": _mean(vmstat.get("id")),
        "cpu_iowait_pct": _mean(vmstat.get("wa")),
        "cpu_steal_pct": _mean(vmstat.get("st")),

        "ctxsw_per_s": _mean(vmstat.get("cs")),
        "interrupts_per_s": _mean(vmstat.get("in")),
        "blocks_in_per_s": _mean(vmstat.get("bi")),
        "blocks_out_per_s": _mean(vmstat.get("bo")),

        "disk_read_iops": _mean(reads_per_s),
        "disk_write_iops": _mean([r.get("w/s") for r in iostat if "w/s" in r]),
        "disk_read_kbps": _mean(rkb_per_s),
        "disk_r_await_ms": _mean([r.get("r_await") for r in iostat if "r_await" in r]),
        "disk_aqu_sz": _mean([r.get("aqu-sz") for r in iostat if "aqu-sz" in r]),
        "disk_util_pct": _mean([r.get("%util") for r in iostat if "%util" in r]),
        "disk_reads_total": int(sum(reads_per_s)) if reads_per_s else None,
        "disk_read_mib": round(sum(rkb_per_s) / 1024, 1) if rkb_per_s else None,
        "disk_read_share": None,

        "db_cpu_pct": _mean(pid.get("%CPU")),
        "db_wait_pct": _mean(pid.get("%wait")),
        "db_majflt_per_s": _mean(pid.get("majflt/s")),
        "rss_mib": round(_mean(pid.get("RSS")) / 1024, 1) if _mean(pid.get("RSS")) else None,
        "db_processes_max": db_processes,
    }

    _r = summary["disk_read_iops"] or 0
    _w = summary["disk_write_iops"] or 0
    if _r + _w > 0:
        summary["disk_read_share"] = round(_r / (_r + _w), 3)
    if args.device_iops_ceiling > 0:
        summary["disk_iops_share_of_ceiling"] = round((_r + _w) / args.device_iops_ceiling, 3)
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
