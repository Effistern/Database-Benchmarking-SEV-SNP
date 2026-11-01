#!/usr/bin/env python3

import argparse
import csv
import json
from collections import defaultdict
from pathlib import Path
from typing import NamedTuple, Optional
import numpy as np
from scipy import stats

CONFIGS = ("none", "sev", "snp")
COMPARISONS = (("H1", "sev", "none"), ("H2", "snp", "none"), ("H3", "snp", "sev"))

class Arm(NamedTuple):
    database: str
    regime: str
    workload: Optional[str]
    table_regime: str
    short: str

ARMS = (
    Arm("mongodb", "resident", None, "resident", "MongoDB res."),
    Arm("mongodb", "exceeding", None, "exceeding", "MongoDB exc."),
    Arm("neo4j", "resident", "ldbc-rw", "resident", "Neo4j res."),
    Arm("neo4j", "exceeding", "ldbc-rw", "exceeding", "Neo4j exc."),
    Arm("postgresql", "resident", "tprocc", "resident, tprocc", "TPROC-C res."),
    Arm("postgresql", "resident", "tproch", "resident, tproch", "TPROC-C res."),
    Arm("postgresql", "exceeding", "tprocc", "exceeding, tprocc", "TPROC-C exc."),
    Arm("postgresql", "exceeding", "tproch", "exceeding, tproch", "TPROC-H exc.")
)

H4_ARMS = (
    ("MongoDB", "mongodb", None),
    ("Neo4j", "neo4j", "ldbc-rw"),
    ("PostgreSQL, tprocc", "postgresql", "tprocc"),
    ("PostgreSQL, tproch", "postgresql", "tproch"),
)

OS_METRICS = (("CPU user", "cpu_user_pct"), ("CPU system", "cpu_system_pct"),
              ("CPU iowait", "cpu_iowait_pct"))

def summarize(overheads):
    x = np.asarray(overheads, dtype=float)
    test = stats.ttest_1samp(x, popmean=0.0)
    ci = test.confidence_interval(confidence_level=0.95)
    sd = x.std(ddof=1)
    return {"n": len(x), "mean": x.mean(), "sd": sd,
            "ci_low": ci.low, "ci_high": ci.high,
            "t": test.statistic, "p": test.pvalue,
            "cohen_dz": x.mean() / sd}

def regime_change(resident, exceeding):
    test = stats.ttest_ind(exceeding, resident, equal_var=False)
    ci = test.confidence_interval(confidence_level=0.95)
    return {"diff": np.mean(exceeding) - np.mean(resident),
            "ci_low": ci.low, "ci_high": ci.high,
            "df": test.df, "p": test.pvalue}

def load_runs(data_dir):
    runs, skipped = {}, 0
    for path in sorted(data_dir.glob("*/campaign_*/*/manifest.json")):
        m = json.loads(path.read_text(encoding="utf-8"))
        if "database" not in m:
            continue
        if m.get("succeeded") is False:
            skipped += 1
            continue
        key = (m["database"], m["regime"], m.get("workload"), m["config"],
               int(m["repetition"]))
        if key in runs:
            raise SystemExit("duplicate run %s: %s" % (key, path))
        runs[key] = m
    return runs, skipped

def value(m):
    return float(m[m["primary_metric"]])

def overhead(a, b, higher_is_worse):
    pct = (a - b) / b * 100.0
    return pct if higher_is_worse else -pct

def paired(runs, db, regime, workload, a, b):
    out = []
    for (d, r, w, c, rep), m in sorted(runs.items()):
        if d != db or r != regime or c != a:
            continue
        if workload is not None and w != workload:
            continue
        partner = runs.get((d, r, w, b, rep))
        if partner is None:
            print(" warning: no %s partner for %s" % (b, (d, r, w, c, rep)))
            continue
        out.append(overhead(value(m), value(partner), m["higher_is_worse"]))
    return out

def workload(runs, db):
    return sorted({w for (d, _r, w, _c, _rep) in runs if d == db})

def sgn(x, digits=2):
    return "$%+.*f$" % (digits, x)

def dtex(d):
    return "$0.0$" if abs(d) < 0.05 else sgn(d, 1)

def ptex(p):
    return "$<0.001$" if p < 0.001 else "$%.3f$" % p

def write_csv(path, rows, fields):
    with path.open(
        "w",
        newline="",
        encoding="utf-8"
    ) as f:
        w = csv.DictWriter(
            f,
            fieldnames=fields
        )
        w.writeheader()
        w.writerows(rows)

def write_tex(path, lines):
    path.write_text("\n".join(lines) + "\n",encoding="utf-8")

def table_main(results):
    lines = [
        r"\begin{table*}[!b]",
        r"  \centering",
        r"  \footnotesize",
        r"  \caption{Overhead by database and working-set regime.}",
        r"  \label{tab:main_result}",
        r"  \begin{tabular}{llrlrlrl}",
        r"    \toprule",
        r"     & & \multicolumn{2}{c}{H1: SEV vs. BVM} & \multicolumn{2}{c}{H2: SEV-SNP vs BVM} & \multicolumn{2}{c}{H3: SEV-SNP vs. SEV} \\",
        r"     \cmidrule(lr){3-4}\cmidrule(lr){5-6}\cmidrule(lr){7-8}",
        r"     Database & Regime & mean & 95\,\% CI & mean & 95\,\% CI & mean & 95\,\% CI \\",
        r"     \midrule", 
    ]
    previous = None
    for arm in ARMS:
        if previous is not None and arm.database != previous:
            lines.append(r"     \addlinespace")
            previous = arm.database
        cells = [arm.database, arm.table_regime]
        for h, _a, _b in COMPARISONS:
            s = results[(arm, h)]
            cells.append(sgn(s["mean"]) + r"\,\%")
            cells.append("[%s, %s]" % (sgn(s["ci_low"]), sgn(s["ci_high"])))
        lines.append("     " + " & ".join(cells) + r" \\")
    lines += [
        r"    \bottomrule",
        r"  \end{tabular}",
        r"  \\[2pt]",
        r"  \begin{minipage}{\linewidth}\footnotesize",
        r"  Mean of paired per-repetition overheads with 95\,\% $t$-intervals; positive values mean slower.",
        r"  $n = 12$ per arm; MongoDB pools YCSB workloads A--F ($n = 72$).",
        r"  \end{minipage}",
        r"\end{table*}"
    ]
    return lines

def table_os(os_means):
    lines = [
        r"\begin{table}[htbp]",
        r"  \centering",
        r"  \footnotesize",
        r"  \caption{Operating-system metrics by configuration and regime.}",
        r"  \label{tab:os_metrics}",
        r"  \begin{tabular}{lrrrrrr}",
        r"     \toprule",
        r"      & \multicolumn{3}{c}{resident} & \multicolumn{3}{c}{exceeding} \\",
        r"      \cmidrule(lr){2-4}\cmidrule(lr){5-7}",
        r"      Metric (\%) & BVM & SEV & SNP & BVM & SEV & SNP \\",
        r"      \midrule", 
    ]
    for label, key in OS_METRICS:
        cells = [label] + ["%.2f" % os_means[(reg, cfg, key)]
                           for reg in ("resident", "exceeding") for cfg in CONFIGS]
        lines.append("     " + " & ".join(cells) + r" \\")
    lines += [
        r"      \bottomrule",
        r"  \end{tabular}",
        r"  \\[2pt]",
        r"  \begin{minipage}{\linewidth}\footnotesize",
        r"  Means over all runs of a regime (all databases and workloads; 72 of 108 runs per cell are MongoDB).",
        r"  \end{minipage}",
        r"\end{table}",
    ]
    return lines

def table_tests(result, n_tests):
    lines = [
        r"\begin{table}[htbp]",
        r"  \centering",
        r"  \footnotesize",
        r"  \caption{Paired $t$-tests against zero and effect sizes}",
        r"  \setlength{\tabcolsep}{4pt}",
        r"  \label{tab:tests}",
        r"  \begin{tabular}{lrrrrrr}",
        r"   \toprule",
        r"   & \multicolumn{2}{c}{H1} & \multicolumn{2}{c}{H2} & \multicolumn{2}{c}{H3} \\",
        r"   \cmidrule(lr){2-3}\cmidrule(lr){4-5}\cmidrule(lr){6-7}",
        r"   Arm & $p$ & $d_z$ & $p$ & $d_z$ & $p$ & $d_z$ \\"
        r"   \midrule",
    ]
    for arm in ARMS:
        cells = [arm.short]
        for h, _, _, in COMPARISONS:
            s = result[(arm, h)]
            cells += [ptex(s["p"]), dtex(s["cohen_dz"])]
        lines.append("     " + " & ".join(cells) + r" \\")
    lines += [
        r"  \bottomrule",
        r"  \end{tabular}",
        r"  \\[2pt]",
        r"  \begin{minipage}{\linewidth}\footnotesize",
        r"  Two-sided one-sample $t$-test of paired overheads. $d_z$ = mean / standard deviation."
        r"  Bonferroni threshold for %d tests: $p < %.4f$" % (n_tests, 0.05 / n_tests),
        r"  \end{minipage}",
        r"\end{table}",
    ]
    return lines

def neo4j_per_query(runs):
    rows = []
    for regime in ("resident", "exceeding"):
        latency = defaultdict(lambda: defaultdict(list))
        count = defaultdict(list)
        for (d, r, _, c, _), m in runs.items():
            if d != "neo4j" or r != regime:
                continue
            for q, e in (m.get("per_query") or {}).items():
                if e.get("mean_us") is None:
                    continue
                latency[q][c].append(float(e["mean_us"]))
                if c == "none":
                    count[q].append(float(e.get("count") or 0))
        for q in sorted(latency):
            if not all(latency[q][c] for c in CONFIGS):
                continue
            base, sev, snp = (np.mean(latency[q][c]) for c in CONFIGS)
            rows.append({
                "regime": regime,
                "query": q,
                "count_per_run": np.mean(count[q]),
                "base_us": base,
                "sev_us": sev,
                "snp_us": snp,
                "sev_delta_us": sev - base,
                "snp_delta_us": snp - base,
                "sev_pct": (sev / base - 1) * 100,
                "snp_pct": (snp / base - 1) * 100,
            })
    return rows

def main():
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", type=Path, default=here / "campaign_data")
    ap.add_argument("--out", type=Path, default=here / "out")
    args = ap.parse_args()

    runs, skipped = load_runs(args.data)
    if not runs:
        raise SystemExit("No runs found")
    args.out.mkdir(parents=True, exist_ok=True)
    print("loaded %d runs from %s" % (len(runs), args.data))

    # Tables: p-value and  H1 - h3 for all arms
    results = {}
    rows = []
    for arm in ARMS:
        for h, a, b in COMPARISONS:
            s = summarize(paired(runs, arm.database, arm.regime, arm.workload, a, b))
            results[(arm, h)] = s
            rows.append(dict(database=arm.database,
                             regime=arm.regime,
                             workload=arm.workload or "ycsb-a..f",
                             comparison=h,
                             **s,
                             ))
    write_csv(args.out / "overheads.csv",
              rows,
              [
                  "database",
                  "regime",
                  "workload",
                  "comparison",
                  "n",
                  "mean",
                  "sd",
                  "ci_low",
                  "ci_high",
                  "t",
                  "p",
                  "cohen_dz"
              ])
    write_tex(args.out / "table_main_result.tex", table_main(results))
    write_tex(args.out / "table_tests.tex", table_tests(results, len(rows)))

    # Table: OS metrics
    samples = defaultdict(list)
    for (_, r, _, c, _), m in runs.items():
        for _label, key in OS_METRICS:
            samples[(r, c, key)].append(float(m["os_summary"][key]))
    os_means = {k: np.mean(v) for k, v in samples.items()}
    write_tex(args.out / "table_os_metrics.tex", table_os(os_means))

    wl_rows = []
    for regime in ("resident", "exceeding"):
        for wl in workload(runs, "mongodb"):
            for h, a, b, in COMPARISONS:
                s = summarize(paired(runs, "mongodb", regime, wl, a, b))
                wl_rows.append(
                    dict(
                        regime=regime,
                        workload=wl,
                        comparison=h,
                        **s
                    ))
    write_csv(args.out / "mongodb_per_workload.csv",
              wl_rows,
              [
                  "regime",
                  "workload",
                  "comparison",
                  "n",
                  "mean",
                  "sd",
                  "ci_low",
                  "ci_high",
                  "t",
                  "p",
                  "cohen_dz"
              ])
    q_rows = neo4j_per_query(runs)
    write_csv(args.out / "neo4j_per_query.csv",
              q_rows,
              [
                  "regime",
                  "query",
                  "count_per_run",
                  "base_us",
                  "sev_us",
                  "snp_us",
                  "sev_delta_us",
                  "snp_delta_us",
                  "sev_pct",
                  "snp_pct",
              ])

if __name__ == "__main__":
    main()