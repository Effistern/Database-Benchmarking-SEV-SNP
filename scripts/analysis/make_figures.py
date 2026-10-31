#!/usr/bin/env python3
import argparse
import csv
import math
from pathlib import Path
import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.ticker import FixedLocator, FuncFormatter, NullFormatter

INK = "black"
INK_2 = "dimgray"
GRID = "gainsboro"
ZERO = "gray"
SEV = "royalblue"
SNP = "chocolate"
COLUMN_IN = 3.5
PAGE_IN = 7.16
TITLES = {"H1": "SEV vs BVM", "H2": "SEV-SNP vs BVM", "H3": "SEV-SNP vs SEV"}

plt.rcParams.update({
    "font.family": "serif",
    "font.serif": "Times New Roman",
    "font.size": 8,
    "axes.titlesize": 8,
    "axes.labelsize": 8,
    "xtick.labelsize": 7,
    "ytick.labelsize": 7.5,
    "legend.fontsize": 7.5,
    "axes.linewidth": 0.6,
    "xtick.major.width": 0.6,
    "xtick.major.size": 2.5,
    "xtick.minor.size": 1.5,
    "axes.edgecolor": ZERO,
    "axes.labelcolor": INK,
    "axes.titlecolor": INK,
    "xtick.color": INK_2,
    "ytick.color": INK,
    "text.color": INK,
    "ps.fonttype": 42,
    "savefig.dpi": 300,
})


def read_csv(path):
    with open(path,
              newline="",
              encoding="utf-8"
              ) as f:
        return list(csv.DictReader(f))


def style_axis(ax, zero_line="x"):
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.tick_params(
        axis="y",
        length=0,
    )
    ax.set_axisbelow(True)
    if zero_line == "x":
        ax.grid(
            axis="x",
            color=GRID,
            linewidth=0.5
        )
        ax.axvline(0,
                   color=ZERO,
                   linewidth=0.7,
                   zorder=1,
                   )
    else:
        ax.grid(
            axis="both",
            which="major",
            color=GRID,
            linewidth=0.5
        )
        ax.axhline(
            0,
            color=ZERO,
            linewidth=0.7,
            zorder=1
        )


def whisker(ax, mean, lo, hi, y, color, marker, filled):
    ax.plot([lo, hi],
            [y, y],
            color=color,
            linewidth=0.9,
            solid_capstyle="butt",
            zorder=2
            )
    ax.plot([mean],
            [y],
            marker=marker,
            markersize=4.2,
            color=color,
            linestyle="none",
            markerfacecolor=color if filled else "white",
            markeredgewidth=0.9,
            zorder=3
            )


def marker_handle(label, color, marker, filled=True):
    return Line2D([],
                  [],
                  marker=marker,
                  markersize=4.2,
                  color=color,
                  linestyle="none",
                  markerfacecolor=color if filled else "white",
                  markeredgewidth=0.9,
                  label=label
                  )


def axis_limits(lows, highs):
    return 5 * math.floor(min(lows) / 5) - 1, 5 * math.ceil(max(highs) / 5) + 1


def save(fig, folder, name):
    fig.savefig(folder / (name + ".png"), dpi=300)
    plt.close(fig)


def figure_overheads(rows, folder):
    groups = (("MongoDB", "mongodb", "ycsb-a..f"), ("Neo4j", "neo4j", "ldbc-rw"),
              ("PostgreSQL TPROC-C", "postgresql", "tprocc"),
              ("PostgreSQL TPROC-H", "postgresql", "tproch"))
    index = {(r["database"], r["workload"], r["regime"], r["comparison"]): r for r in rows}
    lows = [float(r["ci_low"]) for r in rows]
    highs = [float(r["ci_high"]) for r in rows]
    fig, axes = plt.subplots(
        1,
        3,
        figsize=(PAGE_IN, 1.95),
        sharey=True,
        sharex=True,
        layout="constrained"
    )
    for ax, h in zip(axes, ("H1", "H2", "H3")):
        style_axis(ax)
        for i, (_, db, wl) in enumerate(groups):
            y = len(groups) - 1 - i
            for regime, dy, filled in (("resident", 0.15, True), ("exceeding", -0.15, False)):
                r = index[(db, wl, regime, h)]
                whisker(ax, float(r["mean"]), float(r["ci_low"]), float(r["ci_high"]),
                        y + dy, INK, "o", filled)
        ax.set_title("%s: %s" % (h, TITLES[h]), loc="left")
        ax.set_xlabel("Overhead (%)")
    axes[0].set_xlim(*axis_limits(lows, highs))
    axes[0].set_yticks(range(len(groups)))
    axes[0].set_yticklabels([g[0] for g in reversed(groups)])
    axes[0].set_ylim(-0.55, len(groups) - 0.45)
    axes[2].legend(handles=[marker_handle("resident", INK, "o", True),
                            marker_handle("exceeding", INK, "o", False)],
                   loc="lower right",
                   frameon=False,
                   handletextpad=0.3,
                   borderaxespad=0.2,
                   )
    save(fig, folder, "fig1_overheads")


def figure_mongodb(rows, folder):
    wls = sorted({r["workload"] for r in rows})
    index = {(r["regime"], r["workload"], r["comparison"]): r for r in rows if r["comparison"] in ("H1", "H2")}
    lows = [float(r["ci_low"]) for r in index.values()]
    highs = [float(r["ci_high"]) for r in index.values()]
    fig, axes = plt.subplots(1,
                             2,
                             figsize=(COLUMN_IN, 2.3),
                             sharey=True,
                             sharex=True,
                             layout="constrained"
                             )
    for ax, regime in zip(axes, ("resident", "exceeding")):
        style_axis(ax)
        for i, wl in enumerate(wls):
            y = len(wls) - 1 - i
            for h, dy, color, marker in (("H1", 0.16, SEV, "o"), ("H2", -0.16, SNP, "s")):
                r = index[(regime, wl, h)]
                whisker(ax, float(r["mean"]), float(r["ci_low"]), float(r["ci_high"]),
                        y + dy, color, marker, True)
        ax.set_title(regime.capitalize() + " regime", loc="left")
        ax.set_xlabel("Overhead vs BVM (%)")
    axes[0].set_xlim(*axis_limits(lows, highs))
    axes[0].set_yticks(range(len(wls)))
    axes[0].set_yticklabels(["YCSB-" + w[-1].upper() for w in reversed(wls)])
    axes[0].set_ylim(-0.55, len(wls) - 0.45)
    fig.legend(handles=[marker_handle("SEV", SEV, "o"),
                        marker_handle("SEV-SNP", SNP, "s")],
               loc="outside upper right",
               ncol=2,
               frameon=False,
               handletextpad=0.3,
               columnspacing=1.0
               )
    save(fig, folder, "fig2_mongodb_workloads")


def figure_neo4j(rows, folder):
    res = [r for r in rows if r["regime"] == "resident"]
    cheap = [r for r in res if float(r["base_us"]) < 5000]
    med_sev = np.median([float(r["sev_delta_us"]) for r in cheap])
    med_snp = np.median([float(r["snp_delta_us"]) for r in cheap])
    x = [float(r["base_us"]) / 1000.0 for r in res]
    fig, ax = plt.subplots(
        figsize=(COLUMN_IN, 2.35),
        layout="constrained"
    )
    style_axis(ax, zero_line="y")
    ax.spines["left"].set_visible(True)
    ax.tick_params(axis="y",
                   length=2.5,
                   width=0.6,
                   color=INK_2
                   )
    ax.set_xscale("log")
    x_min, x_max = 0.5, 3000.0
    curve_x = np.geomspace(x_min, x_max, 200)
    for delta, color in ((med_snp, SNP), (med_sev, SEV)):
        ax.plot(curve_x,
                (delta / (curve_x * 1000.0) * 100.0),
                color=color,
                linewidth=0.9,
                linestyle=(0, (3, 2)),
                zorder=2
                )
    ax.scatter(x,
               [float(r["sev_pct"]) for r in res],
               s=16,
               marker="o",
               color=SEV,
               edgecolors="white",
               linewidths=0.5,
               zorder=4
               )
    ax.scatter(x,
               [float(r["snp_pct"]) for r in res],
               s=16,
               marker="s",
               color=SNP,
               edgecolors="white",
               linewidths=0.5,
               zorder=4
               )
    ax.set_xlim(x_min, x_max)
    ax.set_ylim(-10, 50)
    ax.xaxis.set_major_locator(FixedLocator([1, 10, 100, 1000]))
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _pos: "%g" % v))
    ax.xaxis.set_minor_formatter(NullFormatter())
    ax.set_xlabel("Mean latency of the query type on the BVM (ms, log scale)")
    ax.set_ylabel("Added latency (%)")
    dashed = (0, (3, 2))
    ax.legend(handles=[marker_handle("SEV", SEV, "o"),
                       marker_handle("SEV-SNP", SNP, "s"),
                       Line2D([],
                              [],
                              color=SEV,
                              linewidth=0.9,
                              linestyle=dashed,
                              label="constant +%.0f \u00b5s" % med_sev
                              ),
                       Line2D([],
                              [],
                              color=SNP,
                              linewidth=0.9,
                              linestyle=dashed,
                              label="constant +%.0f \u00b5s" % med_snp
                              )
                       ],
              loc="upper right",
              frameon=False,
              handletextpad=0.4,
              borderaxespad=0.2
              )
    save(fig, folder, "fig3_neo4j_queries")
    return


def main():
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", type=Path, default=here / "out")
    ap.add_argument("--out", type=Path, default=here / "figures")
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    figure_overheads(read_csv(args.csv / "overheads.csv"), args.out)
    figure_mongodb(read_csv(args.csv / "mongodb_per_workload.csv"), args.out)
    figure_neo4j(read_csv(args.csv / "neo4j_per_query.csv"), args.out)

if __name__ == "__main__":
    main()
