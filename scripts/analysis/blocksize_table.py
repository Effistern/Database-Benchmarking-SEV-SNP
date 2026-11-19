#!/usr/bin/env python3
import argparse
import csv
import json
import os
from pathlib import Path
import numpy as np

COMPARISON_TABLE = (("SEV vs BVM", "sev", "none"),
                    ("SEV-SNP vs BVM", "snp", "none"), ("SEV-SNP vs SEV", "snp", "sev"))
SIZES= ("4k", "16k", "64k")
UNIT = { "k": 1024, "m": 1048576 }

def size_mib(value):
    value = value.lower()
    return int(value[:-1]) * UNIT[value[-1]] / UNIT["m"]

def find_sweeps(roots, depth=3):
    found = []
    for root in roots:
        root = Path(root)
        if not root.is_dir():
            raise SystemError("root is not a directory")
        for dirpath,dirs, _ in os.walk(root):
            path = Path(dirpath)
            if "__iosize__" in path.name:
                found.append(path)
                dirs[:]=[]
            elif len(path.relative_to(root).parts) >= depth:
                dirs[:]=[]
    return sorted(found)

def load(sweeps, warmup=1):
    lat = {}
    for sweep in sweeps:
        config = sweep.name.split("__iosize__")[1].split("__")[0]
        runs = sweep / "runs"
        if not runs.is_dir():
            continue
        for run in sorted(runs.iterdir()):
            fio_json = run / "fio.json"
            if not fio_json.is_file():
                continue
            rep = run.name.rsplit("__r", 1)[1] if "__r" in run.name else ""
            if rep.isdigit() and int(rep) <= warmup:
                continue
            try:
                data = json.loads(fio_json.read_text())
            except json.decoder.JSONDecodeError:
                continue
            pattern, block_size = run.name.split("_")[:2]
            direction = "read" if pattern == "randread" else "write"
            for job in data.get("jobs", []):
                stats = job.get(direction, {})
                if stats.get("io_bytes"):
                    lat.setdefault((config, pattern, block_size), []).append(stats["clat_ns"]["mean"] / 1000.0)
    return lat

def fit (lat, a, b, pattern):
    x = np.array([size_mib(s) for s in SIZES])
    y = np.array([np.mean(lat[(a, pattern, s)]) - np.mean(lat[(b, pattern, s)]) for s in SIZES])
    per_mib, fixed = np.polyfit(x, y, 1)
    return fixed, per_mib, y

def sgn (x, digits=1):
    return "$%+.*f$" % (digits, x)

def table (read_fits):
    lines = [
        r"\begin{table}[t]",
        r"  \centering",
        r"  \footnotesize",
        r"  \caption{Added random-read latency at queue depth~1}"
        r"  \label{tab:blocksize_decomposition}",
        r"  \begin{tabular}{lrrr}",
        r"    \toprule",
        r"    Comparison & fixed & per MiB & added at \\",
        r"     & (\us{}/IO & (\us{}) & 4\,KiB (\us{}) \\",
        r"    \midrule",
    ]
    for label, _, _ in COMPARISON_TABLE:
        fixed, per_mib, y = read_fits[label]
        lines.append("    %s & %s & %d & %s \\\\" % (label, sgn(fixed), round(per_mib), sgn(y[0])))
    lines += [
        r"    \bottomrule",
        r"  \end{tabular}",
        r"  \\[2pt]",
        r"  \begin{minipage}{\linewidth}"
        r"  \footnotesize",
        r"  \end{minipage}",
        r"\end{table}",
    ]
    return lines

def main():
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", type=Path, nargs="+", default=[here / "campaign_data"])
    ap.add_argument("--out", type=Path, default=here / "out")
    args = ap.parse_args()

    sweep = find_sweeps(args.data)
    if not sweep:
        raise SystemExit("no sweeps found")
    lat = load(sweep)
    n = min(len(lat[(c, "randread", s)]) for c in ("none", "sev", "snp") for s in SIZES)
    read_fits = {label: fit(lat, a, b, "randread") for label, a, b in COMPARISON_TABLE}
    write_fits = {label: fit(lat, a, b, "randwrite") for label, a, b in COMPARISON_TABLE}
    for pattern, fits in (("randread", read_fits), ("randwrite", write_fits)):
        for label, (fixed, per_mib, y) in fits.items():
            print("%-9s %-15s fixed %+6.1f us/IO per MiB %+6.0f us added at 4/16/64 KiB %s us"
                  % (pattern, label, fixed, per_mib, ", ".join("%+.1f" % v for v in y)))
    args.out.mkdir(parents=True, exist_ok=True)
    with (args.out / "blocksize.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["pattern", "comparison", "fixed_us", "per_mib_us", "added_4k_us", "added_16k_us", "added_64k_us", "n"])
        for pattern, fits in (("randread", read_fits), ("randwrite", write_fits)):
            for label, (fixed, per_mib, y) in fits.items():
                w.writerow([pattern, label, fixed, per_mib,y[0], y[1], y[2], n])
    (args.out / "table_storage_blocksize.tex").write_text(
        "\n".join(table(read_fits)) + "\n", encoding="utf-8")

if __name__ == "__main__":
    main()