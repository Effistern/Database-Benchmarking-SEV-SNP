# Instructions for MongoDB scripts

## Installing MondoDB

```bash
sudo ./scripts/mongodb/setup.sh --config <none|sev|snp>
```
## Installing YCSB

```bash
sudo ./scripts/mongodb/install_ycsb.sh
```
## Setting up the database

### Creating on one machine

```bash
sudo ./scripts/mongodb/load.sh --config none --records 3000000  --drop
sudo cp /var/lib/db-benchmark/mongodb_dataset /var/lib/db-benchmark/mongodb_dataset.resident

sudo ./scripts/mongodb/load.sh --config none --records 26000000 --drop
sudo cp /var/lib/db-benchmark/mongodb_dataset /var/lib/db-benchmark/mongodb_dataset.exceeding
```

### Pristine directories

```bash
# resident
sudo cp /var/lib/db-benchmark/mongodb_dataset.resident /var/lib/db-benchmark/mongodb_dataset
mongorestore --quiet --drop --nsInclude "ycsb.*" \
  /mnt/dbdata/mongodb_dump/ycsb-r3000000-f100-s20262027
sudo systemctl stop mongod
sudo cp -a /mnt/dbdata/mongodb /mnt/dbdata/pristine_ycsb-r3000000-f100-s20262027
sudo systemctl start mongod

# exceeding
sudo cp /var/lib/db-benchmark/mongodb_dataset.exceeding /var/lib/db-benchmark/mongodb_dataset
mongorestore --quiet --drop --nsInclude "ycsb.*" \
  /mnt/dbdata/mongodb_dump/ycsb-r26000000-f100-s20262027
sudo systemctl stop mongod
sudo cp -a /mnt/dbdata/mongodb /mnt/dbdata/pristine_ycsb-r26000000-f100-s20262027
sudo systemctl start mongod
```

### Propogate to others

```bash

# Datasets
sudo rsync -a --info=progress2 --rsync-path="sudo rsync" \
  -e "ssh -i /home/<user>/.ssh/<key> -o StrictHostKeyChecking=accept-new" \
  /mnt/dbdata/pristine_ycsb-r3000000-f100-s20262027 \
  /mnt/dbdata/pristine_ycsb-r26000000-f100-s20262027 \
  <user>@<vm>:/mnt/dbdata/

# Swap files
scp -i ~/.ssh/<key> /var/lib/db-benchmark/mongodb_dataset.{resident,exceeding} <target>:/tmp/
ssh -i ~/.ssh/<key> <target> 'sudo mv /tmp/mongodb_dataset.{resident,exceeding} /var/lib/db-benchmark/'
```

## Benchmark Test

Quick Test to see if everything is working as intended.

```bash
# Resident
sudo cp /var/lib/db-benchmark/mongodb_dataset.resident /var/lib/db-benchmark/mongodb_dataset
sudo ./scripts/mongodb/run_benchmark.sh --config <none|sev|snp> --regime resident --round <name> \
  --workloads c --repetitions 1 --operations 1 --warmup-operations 0

# Exceeding
sudo cp /var/lib/db-benchmark/mongodb_dataset.exceeding /var/lib/db-benchmark/mongodb_dataset
sudo ./scripts/mongodb/run_benchmark.sh --config <none|sev|snp> --regime exceeding --round <name> \
  --workloads c --repetitions 1 --operations 1 --warmup-operations 0
```

## Running campaign

```bash
sudo ./scripts/mongodb/campaign.sh --config <none|sev|snp>
```