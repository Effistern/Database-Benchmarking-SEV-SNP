import json, sys, pathlib

d = pathlib.Path(sys.argv[1])
max_disk_util = float(sys.argv[2])
try:
    m = json.load(open(d / "manifest.json"))
except Exception:
    print("error 0 0 0 none");
    sys.exit(0)
o = m.get("operation_outcomes", {}) or {}
audit_passed = bool(o.get("schedule_audit_passed"))
disk_util = (m.get("os_summary") or {}).get("disk_util_pct")
if disk_util is None:
    verdict = "error"
elif audit_passed and disk_util <= max_disk_util:
    verdict = "pass"
else:
    verdict = "fail"
print("%s %s %s %.0f %s" % (
    verdict,
    o.get("late", "?"), o.get("total", "?"),
    m.get("latency_mean_us") or 0,
    "none" if disk_util is None else disk_util,
))
