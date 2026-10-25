"""
Usage:
    python per_query_export_tprocc.py [options]
Options:
    --out /path/to/output/file
    --raw /folder/to/data
"""

import argparse
import csv
import json
import os
import sqlite3
import sys

SKIP = {"os_metrics", "db_metrics", "env_check", "__pycache__", "runs"}

procname = {
    "NEWORD", "DELIVERY", "PAYMENT", "SLEV", "OSTAT"
}

subString = {
    "_calls", "_min_ms", "_avg_ms", "_max_ms", "_p50_ms", "_p75_ms", "_p95_ms",
    "_p99_ms", "_sd", "_ratio_pct", "_total_ms"
}

COLUMN = ["database", "regime", "config", "repetition"] + sorted([
    f"{type}{suffix}"
    for type in procname
    for suffix in subString
])


def getTiming(dbPath):
    try:
        conn = sqlite3.connect(dbPath, uri=True)
        rows = list(conn.execute(
            """SELECT vu,
                      procname,
                      calls,
                      min_ms,
                      avg_ms,
                      max_ms,
                      p50_ms,
                      p75_ms,
                      p95_ms,
                      p99_ms,
                      sd,
                      ratio_pct,
                      total_ms
               FROM (SELECT *,
                            ROW_NUMBER() OVER (
            PARTITION BY procname
            ORDER BY calls DESC
            ) AS rn
                     FROM JOBTIMING)
               WHERE rn = 1"""))
        conn.close()
    except sqlite3.OperationalError:
        return None
    return rows


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
    ap.add_argument("--out", default="processed_results/hammerdb_per_query_tprocc.csv")
    args = ap.parse_args()
    roots = args.raw or ["campaign_results"]
    runs = manifests(roots, "campaign_postgres__tpcc")
    if not runs:
        print("No runs found")
        return 1

    rows, skipped = [], 0
    for run in runs:
        pm = run.get("primary_metric")
        if not pm or pm not in run:
            skipped += 1
            continue
        row = {}
        row.update({
            "database": run.get("database", ""),
            "regime": run.get("regime", ""),
            "config": run.get("config", ""),
            "repetition": run.get("repetition", ""),
        })
        path = (run.get("_path").replace("manifest.json", "hammer.DB"))
        timing = getTiming(path)
        for (
                vu, procname, calls, min_ms, avg_ms, max_ms,
                p50_ms, p75_ms, p95_ms, p99_ms, sd,
                ratio_pct, total_ms
        ) in timing:
            row.update({
                f"{procname}_calls": de(calls),
                f"{procname}_min_ms": de(min_ms),
                f"{procname}_avg_ms": de(avg_ms),
                f"{procname}_max_ms": de(max_ms),
                f"{procname}_p50_ms": de(p50_ms),
                f"{procname}_p75_ms": de(p75_ms),
                f"{procname}_p95_ms": de(p95_ms),
                f"{procname}_p99_ms": de(p99_ms),
                f"{procname}_sd": de(sd),
                f"{procname}_ratio_pct": de(ratio_pct),
                f"{procname}_total_ms": de(total_ms),
            })
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


def de(x):
    if isinstance(x, bool) or x == "" or x is None:
        return x
    if isinstance(x, (int, float)):
        return repr(x).replace(".", ",")
    return x


if __name__ == "__main__":
    sys.exit(main())
