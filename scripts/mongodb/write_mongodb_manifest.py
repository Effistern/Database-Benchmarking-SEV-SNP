import datetime
import json
import platform
import subprocess
import sys

(path, run_id, ts, round, config, regime, workload,
 rep, OK, OK_OPS, FAILED_OPS, NOTFOUND, ERRORS,
 THROUGHPUT, OS_PATH, DATA_DEVICE, MANIFESTO, RECORDS, RUN_OPS, RUN_WU,
 OPS_SPEC, WU_SPEC, WARMUP_INSERTS, MEASURED_RECORDCOUNT,
 THREADS, COLD, RESTORE_SECONDS, RESTORE_MODE, VERIFY_METHOD,
 DIR_, DUMP_DIR, DRAIN, YCSB_CORES, SAMPLE_INTERVAL,
 MEASUREMENT_END
 ) =sys.argv[1:]

def sh(command):
  try:
    return subprocess.run(
      command,
      shell=True,
      capture_output=True,
      text=True,
    ).stdout.strip()
  except Exception:
    return "unavailable"

def load_json(path):
  try:
    return json.load(open(path))
  except Exception:
    return None

json.dump({
    "run_id": run_id,
    "timestamp_utc": ts,
    "round": round,
    "config": config,
    "regime": regime,
    "database": "mongodb",
    "tool": "ycsb",
    "workload": f"ycsb-{workload}",
    "repetition": rep,
    "succeeded": OK,
    "primary_metric": "throughput_ops_sec",
    "higher_is_worse": False,
    "operation_outcomes": {
        "successful": OK_OPS,
        "failed": FAILED_OPS,
        "not_found": NOTFOUND,
        "errors": ERRORS,
    },
    "throughput_ops_sec": THROUGHPUT,
    "os_summary": json.load(open(OS_PATH)),
    "data_device": DATA_DEVICE,

    "dataset_on_disk": load_json(MANIFESTO),
    "parameters": {

      "dataset": RECORDS,
      "records": RECORDS,
      "operations": RUN_OPS,
      "warmup_operations": RUN_WU,

      "operations_spec": OPS_SPEC,
      "warmup_operations_spec": WU_SPEC,
      "warmup_inserts": WARMUP_INSERTS,
      "measured_recordcount": MEASURED_RECORDCOUNT,
      "threads": THREADS,
      "cold_start": COLD,
      "restore_before_run": True,
      "restore_seconds": RESTORE_SECONDS,
      "restore_mode": RESTORE_MODE,
      "restore_verified_by": VERIFY_METHOD,
      "restore_source": DIR_,
      "dump_dir": DUMP_DIR,
      "drain_seconds": DRAIN,
      "ycsb_cores": YCSB_CORES,
      "sample_interval_s": SAMPLE_INTERVAL,
    },
    "fixed_work_completion_seconds": MEASUREMENT_END,
    "mongod_affinity": sh(
      "systemctl show mongod.service -p CPUAffinity --value"
    ),
    "mongo_version": sh(
      "mongod --version | awk '/db version/{print $3}'"
    ),
    "kernel": platform.release(),
    "hostname": platform.node(),
    "generated_at_utc": datetime.datetime.now(
      datetime.timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ"),
    },
    open(path, "w"),indent=2)