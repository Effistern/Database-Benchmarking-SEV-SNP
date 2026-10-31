"""
Usage:
    python per_query_export_tproch.py [options]
Options:
    --out /path/to/output/file
    --raw /folder/to/data
"""

import argparse
import csv
import json
import os
import sys

SKIP = {"os_metrics", "db_metrics", "env_check", "__pycache__", "runs"}

query = [
    "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15",
    "16", "17", "18", "19", "20", "21", "22"
]

COLUMN = ["database", "regime", "scale_factor", "config", "repetition"] + query


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
    ap.add_argument("--out", default="processed_results/hammerdb_per_query_tproch.csv")
    args = ap.parse_args()
    roots = args.raw or ["campaign_results"]
    runs = manifests(roots, "campaign_postgres__tproch")
    if not runs:
        print("No runs found")
        return 1

    rows, skipped = [], 0
    for run in runs:
        pm = run.get("primary_metric")
        if not pm or pm not in run:
            skipped += 1
            continue
        per_query = run.get("per_query_seconds") or {}
        row = {}
        row.update({
            "database": run.get("database", ""),
            "regime": run.get("regime", ""),
            "scale_factor": run.get("parameters").get("scale_factor", ""),
            "config": run.get("config", ""),
            "repetition": run.get("repetition", ""),
        })
        for x in query:
            if not per_query.get(x):
                continue
            row.update(makeblock(per_query, x))
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
        x: de(m)
    }


def de(x):
    if isinstance(x, bool) or x == "" or x is None:
        return x
    if isinstance(x, (int, float)):
        return repr(x).replace(".", ",")
    return x


if __name__ == "__main__":
    sys.exit(main())
