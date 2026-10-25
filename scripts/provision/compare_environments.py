import argparse
import json
import sys
from pathlib import Path

CONFIGS = ["none", "sev", "snp"]
EXPECTED_SEV = {
    "none": "none",
    "sev": "sev",
    "snp": "sev-snp",
}

HAS_TO_BE_EQUAL = [
    ("gce.machine_type", "machine type"),
    ("gce.cpu_platform", "CPU platform"),
    ("gce.zone", "zone"),
    ("cpu.model", "CPU model"),
    ("cpu.family", "CPU family"),
    ("cpu.stepping", "CPU stepping"),
    ("cpu.microcode", "microcode"),
    ("cpu.vcpus", "vCPU count"),
    ("cpu.threads_per_core", "threads per core"),
    ("cpu.numa_nodes", "NUMA nodes"),
    ("cpu.governor", "CPU governor"),
    ("gce.image", "OS image"),
    ("os.pretty_name", "OS release"),
    ("os.kernel", "kernel version"),
    ("os.version_id", "OS version id"),
    ("mem.swa_total_kb", "swap size"),
    ("mem.thp", "transparent huge pages"),
    ("mem.hugepages", "hugepages"),
    ("disk.root_fstype", "root filesystem type"),
    ("disk.root_size", "boot disk size"),
    ("datadisk.mount_point", "data disk mount point"),
    ("datadisk.fstype", "data disk filesystem"),
    ("datadisk.options", "data disk mount options"),
    ("datadisk.size", "data disk size"),
    ("datadisk.readahead_kb", "data disk read-ahead"),
    ("datadisk.scheduler", "data disk I/O scheduler"),
    ("datadisk.rotational", "data disk rotational flag"),
    ("db.version", "database version"),
]

HAVE_TO_BE_CHECKED = [
    ("mem.total_mb", "MemTotal"),
    ("dma.swiotlb_mb", "SWIOTLB size"),
    ("dma.swiotlb_nslabs", "SWIOTLB slabs"),
    ("dma.swiotlb_cmdline", "swiotlb= kernel argument"),
    ("pmu.perf_event_paranoid", "perf_event_paranoid"),
    ("pmu.counters_usable", "PMU counters usable"),
    ("disk.root_device", "root device node"),
    ("datadisk.device", "data disk device node"),
    ("datadisk.avail", "data disk free space"),
    ("os.package_count", "installed package count"),
    ("os.uptime_s", "uptime"),
    ("noise.loadavg_1m", "1-minute load average"),
    ("noise.google_ops_agent", "ops agent state")
]


def get(env, dotted, default="<missing>"):
    node = env
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return default
        node = node[part]
    return node if isinstance(node, str) else json.dumps(node)


def collect(args):
    paths = []
    for arg in args:
        p = Path(arg)
        if p.is_dir():
            paths.extend(sorted(p.rglob("environment.json")))
        elif p.is_file():
            paths.append(p)
        else:
            print(f"ERROR: No path: {arg}", file=sys.stderr)
            raise SystemExit(2)
    if not paths:
        print(f"ERROR: No paths found", file=sys.stderr)
        raise SystemExit(2)
    return paths


def load(paths):
    found = {}
    for path in paths:
        env = json.loads(path.read_text())
        config = get(env, "claim.config", "")
        if config not in CONFIGS:
            print(f"WARNING: skipping {path}, unknow config {config!r}", file=sys.stderr)
            continue
        stamp = get(env, "capture.timestamp_utc", "")
        if config not in found or stamp > found[config][2]:
            found[config] = (env, path, stamp)
    return {c: (env, path) for c, (env, path, _) in found.items()}


def interface_of(node):
    base = node.rsplit("/", 1)[-1]
    if base.startswith("nvme"):
        return "NVMe"
    if base.startswith("sd"):
        return "SCSI"
    if base in ("not_mounted", "<missing>"):
        return base
    return f"other({base})"


def describe(vals):
    return ", ".join(f"{c}={v}" for c, v in zip(CONFIGS, vals))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    args = ap.parse_args()

    envs = load(collect(args.paths))
    failures = []
    potential_problems = []
    missing = [c for c in CONFIGS if c not in envs]
    if missing:
        print(f"ERROR: no environment.json for {', '.join(missing)}", file=sys.stderr)
        return 1

    print("=" * 40)
    print("Environement compariso")
    print("=" * 40)
    for c in CONFIGS:
        env, path, = envs[c]
        print(f" {c:<5} {get(env, 'capture.hostname'):<52} {get(env, 'capture.timestamp_utc')}")
        print(f" {path}")
    print()

    print("=" * 40)
    print("Memory encryption (differs)")
    print("=" * 40)
    for c in CONFIGS:
        got, want = get(envs[c][0], "sev.detected"), EXPECTED_SEV[c]
        status = "OK" if got == want else "MISMATCH"
        print(f" {c:<5} detected={got:<10} expected={want:<10} {status}")
        if got != want:
            failures.append(f"{c}: detect '{got}' expected '{want}'")
    seen = {get(envs[c][0], "sev.detected") for c in CONFIGS}
    if len(seen) < 3:
        failures.append(f"encryption states are not distinct: {sorted(seen)}")
    print()

    print("=" * 40)
    print("Has to be the same")
    print("=" * 40)
    width = max(len(label) for _, label in HAS_TO_BE_EQUAL)
    for field, label in HAS_TO_BE_EQUAL:
        vals = [get(envs[c][0], field) for c in CONFIGS]
        if all(v == "<missing>" for v in vals):
            continue
        same = len(set(vals)) == 1
        show = vals[0] if same else " | ".join(f"{c}={v}" for c, v in zip(CONFIGS, vals))
        print(f" {label:<{width}} {'same' if same else 'DIFFERS':<12} {show[:120]}")
        if not same:
            failures.append(f"{label} differs: {describe(vals)}")
    print()

    print("=" * 40)
    print("Has to be check")
    print("=" * 40)
    width = max(len(label) for _, label in HAVE_TO_BE_CHECKED)
    for field, label in HAVE_TO_BE_CHECKED:
        vals = [get(envs[c][0], field) for c in CONFIGS]
        if all(v == "<missing>" for v in vals):
            continue
        same = len(set(vals)) == 1
        show = vals[0] if same else " | ".join(f"{c}={v}" for c, v in zip(CONFIGS, vals))
        print(f" {label:<{width}} {'same' if same else 'DIFFERS':<12} {show[:110]}")
        if not same:
            potential_problems.append(f"{label}: {describe(vals)}")
    print()

    print("=" * 40)
    print("Storage interface")
    print("=" * 40)
    for field, label in (("disk.root_device", "boot disk"), ("datadisk.device", "data disk")):
        interface = {c: interface_of(get(envs[c][0], field)) for c in CONFIGS}
        detail = " | ".join(f"{c}={interface[c]}" for c in CONFIGS)
        if interface["sev"] != interface["snp"]:
            status = "BLOCKED"
            failures.append(f"{label}: SEV and SNP use different interfaces ({detail})")
        elif len(set(interface.values())) > 1:
            status = "Baseline uses a different interface"
        else:
            status = "same"
        print(f"{label:<12} {status:<14} {detail}")
    print()

    print("=" * 40)
    print("CPU flag differences")
    print("=" * 40)
    flags = {c: set(get(envs[c][0], "cpu.flags").split(",")) for c in CONFIGS}
    all_flags = set.union(*flags.values())
    if all_flags != set.intersection(*flags.values()):
        for c in CONFIGS:
            miss = sorted(all_flags - flags[c])
            print(f" {c:<5} missing flags ={', '.join(miss) if miss else '(none)'}")
    print()

    if any(envs[c][0].get("warning") for c in CONFIGS):
        print("=" * 40)
        print("Warnings from verfiy_environment.sh")
        print("=" * 40)
        for c in CONFIGS:
            warnings = envs[c][0].get("warning", [])
            if warnings:
                print(f"{c}:")
                for w in warnings:
                    print(f" - {w}")
        print()

    if failures:
        print("=" * 40)
        print(f"Result: Not comparable, {len(failures)} blocking differences")
        print("=" * 40)
        for f in failures:
            print(f" BLOCKING: {f}")
        return 1
    else:
        print("=" * 40)
        print(f" Result: Comparable")
        print("=" * 40)
    return 0


if __name__ == "__main__":
    sys.exit(main())
