# Instructions for PostgreSQL scripts

## Installing PostgreSQL

```bash
sudo ./scripts/postgresql/postgresSetup.sh --config <none|sev|snp>
```
## Installing HammerDB

```bash
sudo ./scripts/postgresql/install_hammerdb.sh
```
## Setting up the database

### Creating on one machine

```bash
sudo ./scripts/postgresql/setup_db.sh
```

### Propogate to others

```bash

# TPCC
sudo rsync -a --info=progress2 --rsync-path="sudo rsync" \
  -e "ssh -i /home/<user>/.ssh/<key> -o StrictHostKeyChecking=accept-new" \
  /mnt/dbdata/pristine_tpcc-w20 /mnt/dbdata/pristine_tpcc-w260 \
  <user>@<vm>:/mnt/dbdata/

# TPROCH
sudo rsync -a --info=progress2 --rsync-path="sudo rsync" \
  -e "ssh -i /home/<user>/.ssh/<key> -o StrictHostKeyChecking=accept-new" \
  /mnt/dbdata/pristine_tproch-sf1 /mnt/dbdata/pristine_tproch-sf10 \
  <user>@<vm>:/mnt/dbdata/

# Swap files
scp -i ~/.ssh/<key> /var/lib/db-benchmark/postgres_dataset.* <target>:/tmp/
ssh -i ~/.ssh/<key> <target> 'sudo mv /tmp/postgres_dataset.* /var/lib/db-benchmark/'
```

## Running campaign

```bash
sudo ./scripts/postgresql/campaign.sh --config <none|sev|snp>
```