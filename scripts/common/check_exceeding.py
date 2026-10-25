#!/usr/bin/env python3
"""
Usage:
    python3check_exceeding.py <run_dir>/os_summary.json[min_iowait_pct] [min_read_iops]
"""
import json
import sys


def main():
    if len(sys.argv) < 2:
        return 0
    path = sys.argv[1]
    min_iowait = int(sys.argv[2] if len(sys.argv) > 2 else 1.0)
    min_iops = int(sys.argv[3] if len(sys.argv) > 3 else 100.0)
    try:
        summary = json.load(open(path))
    except Exception as exc:
        print(exc)
        return 1
    iowait = summary.get("cpu_iowait_pct", 0.0)
    iops = summary.get("disk_read_iops", 0.0)
    if iowait >= min_iowait and iops >= min_iops:
        print("ok")
    else:
        print("not ok")
    return 0


if __name__ == '__main__':
    sys.exit(main())
