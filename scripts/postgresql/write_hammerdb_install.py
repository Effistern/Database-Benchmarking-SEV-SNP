import json, datetime
import sys

(hammerdb_v, version, hammerdb_home, state) = sys.argv[1:]

json.dump({
    "configured_at_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "hammerdb_version": hammerdb_v,
    "version": version,
    "hammerdb_home": hammerdb_home,
}, open(f"{state}/hammerdb_setup.json","w"), indent=2)