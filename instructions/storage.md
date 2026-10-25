# Instructions for Storage scripts

Used to establish numbers for the storage device

### fio-baseline
```bash
sudo ./scripts/storage/run_fio.sh --config <none|sev|snp>
```

### block-size check
```bash
sudo ./scripts/storage/probe_iosize.sh --config <none|sev|snp>
```

Afterwards pulling and analysing

