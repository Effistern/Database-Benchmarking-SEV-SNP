import json, os, sys, glob, re, math

run_dir, rc = sys.argv[1], int(sys.argv[2])
out = {"driver_exit_code": rc, "parsed": False, "per_query": {},
       "throughput_ops_sec": None, "latency_mean_us": None,
       "latency_p50_us": None, "latency_p95_us": None, "latency_p99_us": None,
       "schedule_audit_passed": None, "late_operations": None, "total_operations": None}

cands = sorted(glob.glob(os.path.join(run_dir, "ldbc_results", "*.json")))
measured = [c for c in cands
            if c.endswith("-results.json") and "WARMUP" not in os.path.basename(c)]
doc = None
for c in measured:
    try:
        d = json.load(open(c))
    except Exception:
        continue
    if isinstance(d, dict):
        doc = d;
        out["results_file"] = os.path.basename(c);
        break
if doc is None:
    out["error"] = ("no measured results file found; candidates were "
                    + ", ".join(os.path.basename(c) for c in cands))


def dig(d, *names):
    for n in names:
        if n in d and d[n] is not None:
            return d[n]
    return None


_TO_US = {"NANOSECONDS": 0.001, "MICROSECONDS": 1.0,
          "MILLISECONDS": 1000.0, "SECONDS": 1000000.0}
if doc:
    out["parsed"] = True
    unit = str(dig(doc, "unit", "time_unit") or "MILLISECONDS").upper()
    scale = _TO_US.get(unit)
    if scale is None:
        out["error"] = f"unrecognised time unit {unit!r}; refusing to guess"
        scale = None
    out["driver_time_unit"] = unit
    out["us_scale_factor"] = scale


    def to_us(v):
        if v is None or scale is None:
            return None
        try:
            return float(v) * scale
        except (TypeError, ValueError):
            return None


    out["total_operations"] = dig(doc, "total_count", "operation_count", "count")
    out["throughput_ops_sec"] = dig(doc, "throughput", "total_throughput", "operations_per_second")
    allm = dig(doc, "all_metrics", "metrics")
    if isinstance(allm, list):
        for m in allm:
            if not isinstance(m, dict):
                continue
            name = str(dig(m, "name", "operation_type") or "").strip()
            rt = dig(m, "run_time", "runtime", "latency") or {}
            if not isinstance(rt, dict):
                rt = {}
            entry = {
                "count": dig(m, "count"),
                "mean_us": to_us(dig(rt, "mean")),
                "p50_us": to_us(dig(rt, "50th_percentile", "p50")),
                "p95_us": to_us(dig(rt, "95th_percentile", "p95")),
                "p99_us": to_us(dig(rt, "99th_percentile", "p99")),
            }
            if name:
                out["per_query"][name] = entry
txt = ""
for f in ("driver.stdout", "driver.stderr"):
    p = os.path.join(run_dir, f)
    if os.path.isfile(p):
        txt += open(p, errors="replace").read()
low = txt.lower()
if "failed schedule audit" in low:
    out["schedule_audit_passed"] = False
elif "passed schedule audit" in low or "schedule audit passed" in low:
    out["schedule_audit_passed"] = True
late_by_op = {op: int(n) for op, n in
              re.findall(r"Late Count for (\S+)\s*\((\d+)\)", txt)}
if late_by_op:
    out["late_operations"] = sum(late_by_op.values())
    out["late_operations_by_type"] = late_by_op
else:
    m = re.search(r"([\d,]+)\s+operations?\s+(?:were\s+)?late", txt, re.I)
    if m:
        out["late_operations"] = int(m.group(1).replace(",", ""))
if out["throughput_ops_sec"] is None:
    m = re.search(r"throughput\D*([\d.]+)", txt, re.I)
    if m:
        out["throughput_ops_sec"] = float(m.group(1))
if out["per_query"]:
    num = den = 0.0
    logs = []
    for e in out["per_query"].values():
        c, mu = e.get("count"), e.get("mean_us")
        if c and mu:
            num += float(c) * float(mu);
            den += float(c)
            if float(mu) > 0:
                logs.append(math.log(float(mu)))
    if den:
        out["latency_mean_us"] = num / den
    if logs:
        out["latency_geomean_us"] = math.exp(sum(logs) / len(logs))
        out["query_types_counted"] = len(logs)
    if den and out["per_query"]:
        shares = {k: (float(v["count"]) * float(v["mean_us"]) / (num or 1))
                  for k, v in out["per_query"].items()
                  if v.get("count") and v.get("mean_us")}
        if shares:
            top = max(shares.items(), key=lambda kv: kv[1])
            out["mean_dominated_by"] = {"query": top[0], "share": round(top[1], 4)}
json.dump(out, sys.stdout, indent=2)
