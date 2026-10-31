import re, sys, csv, statistics as st
from pathlib import Path

runs, csv_path, txt_path, config, rnd, phase, mem_block = sys.argv[1:8]


def parse(text_):
    out = {}
    m = re.search(r"total time:\s*([\d.]+)s", text_)
    if m: out["total_time_s"] = float(m.group(1))
    m = re.search(r"total number of events:\s*(\d+)", text_)
    if m: out["events"] = int(m.group(1))
    m = re.search(r"events per second:\s*([\d.]+)", text_)
    if m: out["events_per_sec"] = float(m.group(1))
    m = re.search(r"\(([\d.]+)\s*MiB/sec\)", text_)
    if m: out["mib_per_sec"] = float(m.group(1))
    m = re.search(r"^\s*([\d.]+)\s*MiB transferred", text_, re.M)
    if m: out["mib_transferred"] = float(m.group(1))
    return out


rows = []
for f in sorted(Path(runs).glob("*.stdout")):
    stem = f.stem
    job, _, rep = stem.rpartition("__r")
    d = parse(f.read_text())
    if not d:
        continue
    rows.append({"config": config, "round": rnd, "phase": phase,
                 "job": job, "rep": int(rep),
                 "total_time_s": d.get("total_time_s", ""),
                 "events": d.get("events", ""),
                 "events_per_sec": d.get("events_per_sec", ""),
                 "mib_per_sec": d.get("mib_per_sec", "")})

if not rows:
    print("WARNING: nothing parsed from sysbench output", file=sys.stderr)
    raise SystemExit(0)

with open(csv_path, "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()));
    w.writeheader();
    w.writerows(rows)

agg = {}
for r in rows:
    agg.setdefault(r["job"], []).append(r)

lines = [f"microbenchmarks config={config} round={rnd} phase={phase}", ""]
hdr = f"{'job':<18} {'n':>2} {'time s':>9} {'cv%':>6} {'events/s':>12} {'MiB/s':>10}"
lines += [hdr, "-" * len(hdr)]
for job in sorted(agg):
    rs = agg[job]
    t = [x["total_time_s"] for x in rs if x["total_time_s"] != ""]
    mean_t = st.mean(t) if t else 0
    cv = (st.pstdev(t) / mean_t * 100) if mean_t and len(t) > 1 else 0.0
    eps = [x["events_per_sec"] for x in rs if x["events_per_sec"] != ""]
    mib = [x["mib_per_sec"] for x in rs if x["mib_per_sec"] != ""]
    lines.append(f"{job:<18} {len(rs):>2} {mean_t:>9.3f} {cv:>6.2f} "
                 f"{(st.mean(eps) if eps else 0):>12.1f} {(st.mean(mib) if mib else 0):>10.1f}")
text = "\n".join(lines)
Path(txt_path).write_text(text + "\n")
print(text)
