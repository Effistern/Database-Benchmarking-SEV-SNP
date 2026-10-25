import csv
import json
import sys
import statistics as st
from pathlib import Path

runs_dir, csv_path, txt_path, config = sys.argv[1:5]

UNIT = {"k": 1024, "m": 1048576}


def block_bytes(token):
    token = token.lower()
    if token[-1] in UNIT:
        return int(token[:-1]) * UNIT[token[-1]]
    return int(token)


rows = []
for run in sorted(Path(runs_dir).iterdir()):
    fio_json = run / "fio.json"
    if not fio_json.is_file():
        continue
    try:
        data = json.loads(fio_json.read_text())
    except json.decoder.JSONDecodeError:
        continue
    for job in data.get("jobs", []):
        parts = job.get("jobname", run.name).split("_")
        if len(parts) < 3:
            continue
        rw = parts[0]
        bs = parts[1]
        nbytes = block_bytes(bs)
        for direction in ("read", "write"):
            stats = job.get(direction, {})
            if not stats.get("io_bytes"):
                continue
            clat = stats.get("clat_ns", {})
            pct = clat.get("percentile", {})
            lat_us = clat.get("mean", 0) / 1000
            rows.append({
                "config": config,
                "pattern": rw,
                "block_size": bs,
                "block_bytes": nbytes,
                "rep": run.name.rsplit("__r", 1)[-1],
                "iops": round(stats.get("iops", 0), 1),
                "bw_mibs": round(stats.get("bw_bytes", 0) / 1048576, 2),
                "lat_mean_us": round(lat_us, 2),
                "lat_p50_us": round(float(pct.get("50.000000", 0)) / 1000, 1),
                "lat_p99_us": round(float(pct.get("99.000000", 0)) / 1000, 1),
                "us_per_mib": round(lat_us / (nbytes / 1048576), 2)
            })

if not rows:
    print("No fio results found", file=sys.stderr)
    raise SystemExit(0)

with open(csv_path, "w", newline="") as file:
    writer = csv.DictWriter(file, fieldnames=list(rows[0].keys()))
    writer.writeheader()
    writer.writerows(rows)

groups = {}
for row in rows:
    groups.setdefault((row["pattern"], row["block_bytes"], row["block_size"]), []).append(row)

lines = [f"block size at qd1 config: {config}"]
header = f"{'pattern':<10} {'bs':<7} {'n':>3} {'IOPS':>10} {'MiB/s':>10} {'per op cost':>12} {'per MiB cost':>12}"
lines += [header, "-" * len(header)]
for (pattern, nbytes, bs), rs in sorted(groups.items()):
    lines.append(
        f"{pattern:<10} {bs:<7} {len(rs):>3}"
        f"{st.mean(r['iops'] for r in rs):>10.1f}"
        f"{st.mean(r['bw_mibs'] for r in rs):>10.2f}"
        f"{st.mean(r['lat_mean_us'] for r in rs):>12.2f}"
        f"{st.mean(r['us_per_mib'] for r in rs):>12.2f}")

text = "\n".join(lines)
Path(txt_path).write_text(text + "\n")
print(text)
