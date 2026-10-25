"""
Usage:
    python per_query_export_ycsb.py [options]
Options:
    --out /path/to/output/file
    --raw /folder/to/data
"""

import argparse
import csv
import json
import os
import re
import sys
import types

SKIP = {"os_metrics", "db_metrics", "env_check", "__pycache__", "runs"}

TYPES = [
    "CLEANUP", "UPDATE", "READ-MODIFY-WRITE",
    "INSERT", "SCAN"
]

subString = {
    "Operations", "AverageLatency(us)",
    "MinLatency(us)", "MaxLatency(us)",
    "50thPercentileLatency(us)", "95thPercentileLatency(us)",
    "99thPercentileLatency(us)"
}

COLUMN = ["database", "regime", "workload", "config", "repetition"] + sorted([
    f"{qType}" + "_" + f"{suffix}"
    for qType in TYPES
    for suffix in subString
])


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
                stdout_path = os.path.join(dirpath, "ycsb.stdout")
                if os.path.isfile(stdout_path):
                    m["_ycsb_stdout"] = stdout_path
                else:
                    m["_ycsb_stdout"] = None
                seen[key] = m
    return [seen[x] for x in sorted(seen)]


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--raw", action="append", default=None)
    ap.add_argument("--out", default="processed_results/ycsb_per_type.csv")
    args = ap.parse_args()
    roots = args.raw or ["campaign_results"]
    runs = manifests(roots, "campaign_mongo")
    if not runs:
        print("No runs found")
        return 1

    rows, skipped = [], 0
    for run in runs:
        pm = run.get("primary_metric")
        if not pm or pm not in run:
            skipped += 1
            continue

        metrics = {}
        ycsb = run.get("_ycsb_stdout")
        with open(ycsb) as f:
            for line in f:
                match = re.match(r"\[([^]]+)], ([^,]+), (.+)", line.strip())
                if not match:
                    continue
                operation, metric, value = match.groups()
                if metric not in subString:
                    continue
                metrics.setdefault(operation, {})[metric] = float(value)
        row = {}
        row.update({
            "database": run.get("database", ""),
            "regime": run.get("regime", ""),
            "workload": run.get("workload", ""),
            "config": run.get("config", ""),
            "repetition": run.get("repetition", ""),
        })
        for qType in TYPES:
            if not metrics.get(qType):
                continue
            row.update(makeblock(metrics, qType))
        rows.append(row)
    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMN, delimiter=";")
        w.writeheader()
        w.writerows(rows)
    print("wrote {} rows".format(len(rows)))
    return 0


def makeblock(metrics, x):
    m = metrics.get(x, {})
    return {
        f"{x}_Operations": de(m.get("Operations")),
        f"{x}_AverageLatency(us)": de(m.get("AverageLatency(us)")),
        f"{x}_MinLatency(us)": de(m.get("MinLatency(us)")),
        f"{x}_MaxLatency(us)": de(m.get("MaxLatency(us)")),
        f"{x}_50thPercentileLatency(us)": de(m.get("50thPercentileLatency(us)")),
        f"{x}_95thPercentileLatency(us)": de(m.get("95thPercentileLatency(us)")),
        f"{x}_99thPercentileLatency(us)": de(m.get("99thPercentileLatency(us)")),
    }


def de(x):
    if isinstance(x, bool) or x == "" or x is None:
        return x
    if isinstance(x, (int, float)):
        return repr(x).replace(".", ",")
    return x


if __name__ == "__main__":
    sys.exit(main())
