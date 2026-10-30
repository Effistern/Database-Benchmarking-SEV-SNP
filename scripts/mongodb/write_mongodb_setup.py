import json, subprocess, datetime, sys

(PATH ,CONFIG ,CACHE_GB, EFF_CACHE, DBPATH, DEV_DATA, BIND_IP, ACT_AFF,
 USE_AFFINITY, MEM_MB) = sys.argv[1:]

def sh(c):
  try: return subprocess.run(c, shell=True, capture_output=True, text=True).stdout.strip()
  except Exception: return "unavailable"

json.dump({
  "configured_at_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "config": CONFIG,
  "mongo_version": sh("mongod --version | awk '/db version/{print $3}'"),
  "requested_cache_gb": CACHE_GB,
  "effective_cache_bytes": EFF_CACHE,
  "dbpath": DBPATH,
  "data_device": DEV_DATA,
  "bind_ip": BIND_IP,
  "cpu_affinity": ACT_AFF,
  "affinity_enabled": USE_AFFINITY,
  "mem_total_mb": MEM_MB,
  "lscpu_topology": sh("lscpu -p=CPU,CORE,SOCKET | grep -v '^#' | tr '\n' ';'"),
}, open(PATH,"w"), indent=2)