import argparse
import csv
import sys
from collections import defaultdict
import statistics as st
from pathlib import Path

CONFIGS = ["none", "sev", "snp"]
PHASE_ORDER = {"pre": 0, "mid": 1, "post": 2}
DRIFT_TOLERANCE = 2.0
CPU_TOLERANCE = 2.0


def load(root):
    data = defaultdict(list)
    found = []
    for x in sorted(root.rglob("summary.csv")):
        if "__microbench__" not in str(x.parent):
            continue
        if any((d / "INVALID").exists() for d in x.parent.iterdir()):
            continue
        found.append(x)
        for row in csv.DictReader(open(x)):
            if row.get("total_time_s"):
                key = (row["config"], row.get("phase", "pre"), row["job"])
                data[key].append(float(row["total_time_s"]))
    return data, found


def mean(data, config, phase, job):
    values = data.get((config, phase, job))
    return st.mean(values) if values else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    args = ap.parse_args()

    root = Path(args.path)
    if not root.exists():
        print("Path", root, "does not exist", file=sys.stderr)
        return 2
    data, found = load(root)
    if not data:
        print("No data found", file=sys.stderr)
        return 2
    phases = sorted({k[1] for k in data}, key=lambda p: (PHASE_ORDER.get(p, 1), p))
    jobs = sorted({k[2] for k in data})
    present = sorted({k[0] for k in data}, key=lambda c: CONFIGS.index(c) if c in CONFIGS else 9)
    others = [c for c in present if c != "none"]

    print("=" * 40)
    print(f"Microbenchmarks analysis {root.name}")
    print("=" * 40)
    print(f"Configs: {', '.join(present)}, phases: {', '.join(phases)}")
    print(f" found {len(found)} microbenchmarks")
    print()

    for phase in phases:
        print("=" * 40)
        print(f"Phase: {phase} (lower is faster")
        print("=" * 40)
        print(f"{'jobs':<18}" + "".join(f"{c:>12}" for c in present) + f"{'spread %':>10}")
        for job in jobs:
            vals = {c: mean(data, c, phase, job) for c in present}
            if None in vals.values() or not vals["none"]:
                continue
            lo = min(vals.values())
            hi = max(vals.values())
            spread = 100 * (hi - lo) / lo if lo else 0.0
            flag = ""
            if job.startswith("cpu") and spread > CPU_TOLERANCE:
                flag = " CPU speeds differ strongly"
            print(f"{job:<18}" + "".join(f"{vals[c]:>12.3f}" for c in present) + f"{spread:>10.2f}{flag}")
        print()

        if "none" in present:
            print("=" * 40)
            print("Relative to none (+ means slower)")
            print("=" * 40)
            for job in jobs:
                vals = {c: mean(data, c, phase, job) for c in present}
                if None in vals.values() or not vals["none"]:
                    continue
                base = vals["none"]
                rel = "   ".join(f"{c}={100 * (vals[c] - base) / base:+6.2f}%" for c in others)
                print(f"{job:<18}" + rel)
            print()
    return None


if __name__ == "__main__":
    sys.exit(main())
