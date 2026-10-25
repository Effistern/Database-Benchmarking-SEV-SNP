import json
import sys

facts_path, json_path = sys.argv[1:]

out = {}
for line in open(facts_path, errors="replace"):
    key, _, value = line.rstrip("\n").partition("\t")
    if not key:
        continue
    if key.endswith("[]"):
        out.setdefault(key[:-2], []).append(value)
        continue
    *parents, name = key.split(".")
    node = out
    for parent in parents:
        node = node.setdefault(parent, {})
    node[name] = value

with open(json_path, "w") as file:
    json.dump(out, file, indent=2, sort_keys=True)
    file.write("\n")
