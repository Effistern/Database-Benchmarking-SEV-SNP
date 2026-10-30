import json
import sys
(collstats_file, out_file, dataset_id, records, fieldlength, seed, verified_count, load_seconds) =sys.argv[1:9]

def as_int(value):
  if isinstance(value, dict):
    for key in ("$numberLong", "$numberInt", "$numberDouble"):
      if key in value:
        value = value[key]
        break
  return int(float(value))

raw = json.load(open(collstats_file))
if not raw or "storageStats" not in raw[0]:
  sys.exit("noStorageStats in %s" % collstats_file)
storage = raw[0]["storageStats"]

sizes = {}
for key in ("count", "size", "storageSize", "totalIndexSize"):
  if key not in storage:
    sys.exit("storageStats has no %r in %s" % (key, collstats_file))
  sizes[key] = as_int(storage[key])
  if sizes[key] <= 0:
    sys.exit("storageStats.%s is %d in %s" % (key, sizes[key], collstats_file))

if sizes["count"] != int(verified_count):
  sys.exit("storageStats.count is %d but countDocuments returned %s" % (sizes["count"], verified_count))

json.dump({
  "dataset_id": dataset_id,
  "records_requested": int(records),
  "documents_verified": int(verified_count),
  "fieldlength": int(fieldlength),
  "seed": int(seed),
  "load_seconds": int(load_seconds),
  "size_bytes": sizes["size"],
  "storage_size_bytes": sizes["storageSize"],
  "total_index_size_bytes": sizes["totalIndexSize"],
  "parsed_from": collstats_file,
  }, open(out_file, "w"), indent=2)

print(sizes["size"] // 1048576)