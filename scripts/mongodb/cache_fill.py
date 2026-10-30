import json
import os
import sys

def read_cache_bytes(path):
  with open(path) as f:
    value = json.load(f)["wiredTiger"]["cache"]["bytes read into cache"]

  if isinstance(value, dict):
    return (value["high"] << 32) + (value["low"] & 0xffffffff)

  return int(value)

base = sys.argv[1]

before = read_cache_bytes(
  os.path.join(base, "serverstatus_after_warmup.json")
)

after = read_cache_bytes(
os.path.join(base, "serverstatus_after.json")
)

print ((after - before) // 1048576)