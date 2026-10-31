#!/usr/bin/env python3
"""
Usage:
    python per_query_export_neo4j.py [options]
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

queries = [
    "LdbcQuery1", "LdbcQuery2", "LdbcQuery3", "LdbcQuery4",
    "LdbcQuery5", "LdbcQuery6", "LdbcQuery7", "LdbcQuery8",
    "LdbcQuery9", "LdbcQuery10", "LdbcQuery11", "LdbcQuery12",
    "LdbcQuery13", "LdbcQuery14",
    "LdbcShortQuery1PersonProfile", "LdbcShortQuery2PersonPosts",
    "LdbcShortQuery3PersonFriends", "LdbcShortQuery4MessageContent",
    "LdbcShortQuery5MessageCreator", "LdbcShortQuery6MessageForum",
    "LdbcShortQuery7MessageReplies",
    "LdbcUpdate1AddPerson", "LdbcUpdate2AddPostLike",
    "LdbcUpdate3AddCommentLike", "LdbcUpdate4AddForum",
    "LdbcUpdate5AddForumMembership", "LdbcUpdate6AddPost",
    "LdbcUpdate7AddComment", "LdbcUpdate8AddFriendship",
]

subString = {
    "_count", "_mean_us",
    "_p50_us", "_p95_us",
    "_p99_us"
}

COLUMN = ["database", "regime", "workload", "config", "repetition"] + sorted([
    f"{query}{suffix}"
    for query in queries
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
                seen[key] = m
    return [seen[x] for x in sorted(seen)]


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--raw", action="append", default=None)
    ap.add_argument("--out", default="processed_results/ldbc_per_query.csv")
    args = ap.parse_args()
    roots = args.raw or ["campaign_results"]
    runs = manifests(roots, "campaign_neo4j")
    if not runs:
        print("No runs found")
        return 1

    rows, skipped = [], 0
    for run in runs:
        pm = run.get("primary_metric")
        if not pm or pm not in run:
            skipped += 1
            continue
        per_query = run.get("per_query") or {}
        row = {}
        row.update({
            "database": run.get("database", ""),
            "regime": run.get("regime", ""),
            "config": run.get("config", ""),
            "repetition": run.get("repetition", ""),
        })
        for x in queries:
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


def makeblock(per_query, x):
    m = per_query.get(x, {})
    return {
        f"{x}_count": de(m.get("count")),
        f"{x}_mean_us": de(m.get("mean_us")),
        f"{x}_p50_us": de(m.get("p50_us")),
        f"{x}_p95_us": de(m.get("p95_us")),
        f"{x}_p99_us": de(m.get("p99_us")),
    }


def de(x):
    if isinstance(x, bool) or x == "" or x is None:
        return x
    if isinstance(x, (int, float)):
        return repr(x).replace(".", ",")
    return x


if __name__ == "__main__":
    sys.exit(main())
