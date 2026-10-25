# Instructions for Provision scripts

Used to compare environments and create the same working ground

### Upload scripts (NOT VM)
```
sudo ./push.sh
```

### Prepare vm
```bash 
sudo ./scripts/provision/prepare_vm.sh
```

### Get the environment
```bash 
sudo ./scripts/provision/verify_environment.sh --config <none|sev|snp>
```

### Download environment from vms (NOT VM)
```
sudo ./pull.sh
```

### Compare environments (NOT VM)
```bash
python3 ./scripts/provision/compare_environments.py ./raw_results/env_check/vm-none_<TS> \
./raw_results/env_check/vm-sev_<TS> ./raw_results/env_check/vm-snp_<TS>

```