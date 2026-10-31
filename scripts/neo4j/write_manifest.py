import json, subprocess, datetime, platform, sys

(manifest_path, parsed_path, directory, run_id, ts, round_, config, regime, workload,
 rep, ok, data_device, dataset, tcr, operation, warmup_ops, threads, driver_cores,
 cooldown, sample_interval, restore_seconds, elapsed, state, ldbc_home,
 driver_java_home, load_avg) = sys.argv[1:27]


def sh(c):
    try:
        return subprocess.run(c, shell=True, capture_output=True, text=True).stdout.strip()
    except Exception:
        return "unavailable"


p = json.load(open(parsed_path))
json.dump({
    "run_id": run_id,
    "timestamp_utc": ts, "round": round_, "config": config,
    "regime": regime,
    "database": "neo4j", "tool": "ldbc-snb-interactive-v1", "workload": workload,
    "repetition": rep, "succeeded": ok,
    "primary_metric": ("latency_geomean_us"
                       if regime == "resident"
                       else "fixed_work_completion_seconds"),
    "higher_is_worse": True,
    "latency_mean_us": p.get("latency_mean_us"),
    "latency_geomean_us": p.get("latency_geomean_us"),
    "mean_dominated_by": p.get("mean_dominated_by"),
    "driver_time_unit": p.get("driver_time_unit"),
    "results_file": p.get("results_file"),
    "throughput_ops_sec": p.get("throughput_ops_sec"),
    "operation_outcomes": {
        "total": p.get("total_operations"),
        "late": p.get("late_operations"),
        "late_by_type": p.get("late_operations_by_type"),
        "schedule_audit_passed": p.get("schedule_audit_passed"),
    },
    "per_query": p.get("per_query"),
    "os_summary": json.load(open(directory)),
    "data_device": data_device,
    "parameters": {
        "dataset": dataset,
        "time_compression_ratio": tcr,
        "operations": operation, "warmup_operations": warmup_ops,
        "threads": threads, "driver_cores": driver_cores,
        "cooldown_seconds": cooldown, "sample_interval_s": sample_interval,
        "restore_seconds": restore_seconds,
    },
    "fixed_work_completion_seconds": elapsed,
    "neo4j_affinity": sh("systemctl show neo4j.service -p CPUAffinity --value"),
    "neo4j_version": sh("dpkg-query -W -f='${Version}' neo4j"),
    "ldbc_commit": sh("awk -F= '/^commit=/{print $2}' " + state + "/ldbc_install"),
    "query_files": sh("ls " + ldbc_home + "/cypher/queries/*.cypher 2>/dev/null | wc -l"),
    "ldbc_version": "v1",
    "driver_java_major": driver_java_home,
    "driver_java_home": driver_java_home,
    "kernel": platform.release(), "hostname": platform.node(),
    "load_before_run": load_avg,
    "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, open(manifest_path, "w"), indent=2)
