import json, sys

summary = json.load(open(sys.argv[1]))
min_iowait, min_iops = float(sys.argv[2]), float(sys.argv[3])
iowait = summary.get("cpu_iowait_pct")
iops = summary.get("disk_read_iops")
if iowait is None or iops is None:
    print("unknown: the os_summary has no cpu_iowait_pct or disk_read_iops")
elif iowait < min_iowait or iops < min_iops:
    print("low: cpu_iowait_pct %.2f, dick_read_iops %.1f" % (iowait, iops))
else:
    print("ok: cpu_iowait_pct %.2f, disk_read_iops %.1f" % (iowait, iops))