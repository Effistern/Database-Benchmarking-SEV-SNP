import sys, json, subprocess, platform, datetime, os

(out_path,ts, round_name, config, workload, regime, rep, ok,nopm, tpm, geomean, actual_scale,threads, rampup,
 duration, sample_int, elapsed, load1, dataset_id, ds_rows, ds_rows_table, ds_bytes, data_device,
 os_summary_path, postgres_unit
) = sys.argv[1:]

def safe_float(val, default=0.0):
    try: return float(str(val).strip())
    except (ValueError, TypeError): return default

def safe_int(val, default=0):
    try: return int(str(val).strip())
    except (ValueError, TypeError): return default

def sh(c):
    try: return subprocess.run(c, shell=True, capture_output=True, text=True).stdout.strip()
    except Exception: return "unavailable"

def load_json(p):
    try:
        with open(p) as f: return json.load(f)
    except Exception: return {}

def load_per_query(run_dir):
    p = os.path.join(run_dir, "db_metrics", "per_query_seconds.tsv")
    out = {}
    try:
        with open(p) as f:
            for line in f:
                q, s = line.split()
                out[int(q)] = float(s)
    except Exception:
        pass
    return out

if workload == "tprocc":
    primary_metric, higher_is_worse = "nopm", False
else:
    primary_metric, higher_is_worse = "geomean_seconds", True

data = {
    "run_id": f"{ts}__postgres__{config}__{workload}_{regime}__r{rep}",
    "timestamp_utc": ts,
    "round": round_name,
    "config": config,
    "database": "postgresql",
    "tool": "hammerdb",
    "workload": workload,
    "regime": regime,
    "primary_metric": primary_metric,
    "higher_is_worse": higher_is_worse,
    "nopm": safe_int(nopm, 0),
    "tpm": safe_int(tpm, 0),
    "geomean_seconds": safe_float(geomean, 0.0),
    "repetition": safe_int(rep, 1),
    "succeeded": str(ok).lower() in ("true", "1"),
    "metrics": {
        "nopm": safe_int(nopm, 0),
        "tpm": safe_int(tpm, 0),
        "geomean_seconds": safe_float(geomean, 0.0),
    },
    "os_summary": load_json(os_summary_path),
    "data_device": data_device,
    "postgres_unit": postgres_unit,
    "per_query_seconds": load_per_query(os.path.dirname(os_summary_path)),
    "dataset": {
        "dataset_id": dataset_id,
        "rows_table": ds_rows_table,
        "rows_recorded_at_capture": safe_int(ds_rows, 0),
        "pristine_bytes": safe_int(ds_bytes, 0),
        "mem_total_mb": safe_int(sh("awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo"), 0),
    },
    "parameters": {
        "warehouses": safe_int(actual_scale, 0) if workload == "tprocc" else None,
        "scale_factor": safe_int(actual_scale, 0) if workload == "tproch" else None,
        "virtual_users": safe_int(threads, 2),
        "rampup_minutes": safe_int(rampup, 0) if workload == "tprocc" else None,
        "duration_minutes": safe_int(duration, 3) if workload == "tprocc" else None,
        "sample_interval_s": safe_int(sample_int, 1)
    },
    "completion_seconds": safe_int(elapsed, 0),
    "pg_version": sh("sudo -u postgres psql -tAc 'SHOW server_version;'") or sh("psql --version | '{print $3}'"),
    "kernel": platform.release(),
    "hostname": platform.node(),
    "load_before_run": str(load1),
    "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
}

with open(out_path, "w") as f:
    json.dump(data, f, indent=2)