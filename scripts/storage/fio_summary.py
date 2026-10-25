import csv
import json
import sys
from pathlib import Path
import statistics as st

runs_dir, csv_path, txt_path, config = sys.argv[1:5]

PERCENTILES = {
    "lat_p50_us": "50.000000",
    "lat_p90_us": "90.000000",
    "lat_p95_us": "95.000000",
    "lat_p99_us": "99.000000",
    "lat_p999_us": "99.900000",
    "lat_p9999_us": "99.990000"
}

rows = []
for run in sorted(Path(runs_dir).iterdir()):
    fio_json = run / "fio.json"
    if not fio_json.is_file():
        continue
    try:
        data = json.loads(fio_json.read_text())
    except json.decoder.JSONDecodeError:
        continue
    rep = run.name.split("__r", 1)[-1]
    for job in data.get("jobs", []):
        for direction in ("read", "write"):
            stats = job.get(direction, {})
            if not stats.get("io_bytes"):
                continue
            clat = stats.get("clat_ns", {})
            pct = clat.get("percentile", {})
            row = {
                "config": config,
                "job": job.get("jobname", run.name),
                "rep": rep,
                "direction": direction,
                "iops": round(stats.get("iops", 0), 1),
                "bw_mibs": round(stats.get("bw_bytes", 0) / 1048576, 2),
                "lat_mean_us": round(clat.get("mean", 0) / 1000, 1),
            }
            for name, key in PERCENTILES.items():
                row[name] = round(float(pct.get(key, 0)) / 1000, 1)
            rows.append(row)
if not rows:
    print("No fio results found", file=sys.stderr)
    raise SystemExit(0)

with open(csv_path, "w", newline="") as file:
    writer = csv.DictWriter(file, fieldnames=list(rows[0].keys()))
    writer.writeheader()
    writer.writerows(rows)

groups = {}
for row in rows:
    groups.setdefault((row["job"], row["direction"]), []).append(row)

lines = [f"fio storage baseline config: {config}", ""]
header = f"{'job':<20} {'dir':<6} {'n':>2} {'IOPS':>9} {'MiB/s':>9} {'lat p50 us':>11} {'p95 us':>9} {'p99':>9} {'CV%':>6}"
lines += [header, "-" * len(header)]
for (job, direction), rs in sorted(groups.items()):
    iops = [r["iops"] for r in rs]
    mean_iops = st.mean(iops)
    cv = (st.pstdev(iops) / mean_iops * 100) if mean_iops and len(iops) > 1 else 0.0
    lines.append(
        f"{job:<20} {direction:<6} {len(rs):>2} {mean_iops:>9.1f}"
        f"{st.mean(r['bw_mibs'] for r in rs):>9.2f}"
        f"{st.mean(r['lat_p50_us'] for r in rs):>11.1f}"
        f"{st.mean(r['lat_p95_us'] for r in rs):>9.1f}"
        f"{st.mean(r['lat_p99_us'] for r in rs):>9.1f}"
        f"{cv:>6.1f}")
text = "\n".join(lines)
Path(txt_path).write_text(text + "\n")
print(text)
