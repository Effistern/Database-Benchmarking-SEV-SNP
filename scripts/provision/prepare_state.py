import json, sys, datetime
from pathlib import Path

dst, mount, device, thp, ra, scheduler, diskname, *changes = sys.argv[1:]

Path(dst).parent.mkdir(parents=True, exist_ok=True)

json.dump({
    "prepared_at_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "diskname": diskname,
    "mount_point": mount,
    "device": device,
    "thp": thp,
    "read_ahead_kb": ra,
    "io_scheduler": scheduler,
    "changes:": [c for c in changes if c],
}, open(dst, "w"), indent=2)
open(dst, "a").write("\n")
