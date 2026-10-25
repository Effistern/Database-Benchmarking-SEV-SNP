#!/usr/bin/env python3
"""
Usage: export_runs.py [options]
Options:
    --out /path/to/output/file.csv
    --raw /folder/to/data
"""
import argparse
import csv
import json
import os
import sys

SKIP = {"os_metrics", "db_metrics", "env_check", "__pycache__", "runs"}

COLUMNS = [
    "database", "regime", "workload", "config", "repetition", "primary_metric",
    "value", "higher_is_worse", "dataset_id",
    "ops_failed", "schedule_ok", "ops_late",
    "cpu_user_pct", "cpu_system_pct", "cpu_iowait_pct",
    "cpu_steal_pct", "db_cpu_pct", "rss_mid", "data_device",
    "disk_read_mib", "disk_read_total", "ceiling_share"
]


def manifests(roots, round_filter):
    seen = {}
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, dirs, filenames in os.walk(root):
            dirs[:] = [d for d in dirs if d not in SKIP]
            if "manifest.json" not in filenames:
                continue
            path = os.path.join(dirpath, "manifest.json")
            try:
                m = json.load(open(path))
            except json.decoder.JSONDecodeError as e:
                print(e)
                continue
            if m.get("succeeded", None) is False:
                continue
            if round_filter and round_filter not in (m.get("round") or ""):
                continue
            key = m.get("run_id") or path
            if key not in seen:
                m["_path"] = path
                seen[key] = m
    return [seen[x] for x in sorted(seen)]


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--raw", action="append", default=None)
    ap.add_argument("--out", default="processed_results/processed_results.csv")
    args = ap.parse_args()
    roots = args.raw or ["campaign_results"]
    runs = manifests(roots, "campaign")
    if not runs:
        print("No runs found")
        return 1

    rows, skipped = [], 0
    for run in runs:
        pm = run.get("primary_metric")
        if not pm or pm not in run:
            skipped += 1
            continue
        _os = run.get("os_summary") or {}
        rows.append({
            "database": run.get("database", ""),
            "regime": run.get("regime", ""),
            "workload": run.get("workload", ""),
            "config": run.get("config", ""),
            "repetition": run.get("repetition", ""),
            "primary_metric": pm,
            "value": de(run[pm]),
            "higher_is_worse": run.get("higher_is_worse", ""),
            "dataset_id": (run.get("dataset") or {}).get("dataset_id", "")
                          or (run.get("parameters") or {}).get("dataset") or "",
            "ops_failed": (run.get("operation_outcomes") or {}).get("failed") or "",
            "schedule_ok": (run.get("operation_outcomes") or {}).get("schedule_audit_passed") or "",
            "ops_late": (run.get("operation_outcomes") or {}).get("late") or "",
            "cpu_user_pct": de(_os.get("cpu_user_pct", "")),
            "cpu_system_pct": de(_os.get("cpu_system_pct", "")),
            "cpu_iowait_pct": de(_os.get("cpu_iowait_pct", "")),
            "cpu_steal_pct": de(_os.get("cpu_steal_pct", "")),
            "db_cpu_pct": de(_os.get("db_cpu_pct", "")),
            "data_device": run.get("data_device", ""),
            "disk_read_mib": de(_os.get("disk_read_mib", "")),
            "disk_read_total": de(_os.get("disk_read_total", "")),
            "ceiling_share": de(_os.get("ceiling_share", "")),
            "rss_mid": de(_os.get("rss_mid", "")),
        })
    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS, delimiter=";")
        w.writeheader()
        w.writerows(rows)
    print("wrote {} rows".format(len(rows)))
    return 0


def de(x):
    if isinstance(x, bool) or x == "" or x is None:
        return x
    if isinstance(x, (int, float)):
        return repr(x).replace(".", ",")
    return x


if __name__ == "__main__":
    sys.exit(main())
