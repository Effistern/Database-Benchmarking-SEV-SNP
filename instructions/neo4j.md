# Instructions for Neo4j scripts

Commands are supposed to be executed in order and lives under `scripts/neo4j`

## The general order

__Install Neo4j &rarr; install ldbc &rarr; load dataset &rarr; create driver properties &rarr; propagate dataset &rarr;
validate once &rarr; calibrate trc &rarr; benchmark__

## Install Neo4j

```bash
# Using the defaults
sudo ./scripts/neo4j/install_neo4j.sh --config <none|sev|snp>

#Using different heap and pagecache
sudo ./scripts/neo4j/install_neo4j.sh --config <none|sev|snp> --heap-gb 4 --pagecache-gb 6
```

To manually check if everything worked and the data mount is the right

```bash
grep -E "directories.(data|transaction)" /etc/neo4j/neo4j.conf
```

It should display the following

```
dbms.directories.data=/mnt/dbdata/neo4j/data
dbms.directories.transaction.logs.root=/mnt/dbdata/neo4j/transactions
```

## Install LDBC

```bash
# Using the defaults
sudo ./scripts/neo4j/install_ldbc.sh

#Using a diffeent commit
sudo ./scripts/neo4j/install_ldbc.sh --commit 11db98cc2ba14c33492f6c0c34e68c8be7e22e5f
```

## Datasets

For each dataset upload and unpack into the following

Dataset used by us \

SF1
* social_network-sf1-CsvComposite-LongDateFormatter
* social_network-sf1-numpart-1
* substitution_parameters-sf1
* validation_params-interactive-v1.0.0-sf0.1-to-sf10

SF10
+ social_network-sf10-CsvComposite-LongDateFormatter
+ social_network-sf10-numpart-1
+ substitution_parameters-sf10
+ validation_params-interactive-v1.0.0-sf0.1-to-sf10

```bash
SF=1 || 10
gcloud compute scp --recurse ./scripts/neo4j/dataset/sf${SF} <user>@<vm-conf>:~/dataset

sudo mkdir -p /mnt/dbdata/ldbc-v1 && sudo chown "$USER" /mnt/dbdata/ldbc-v1
cd /mnt/dbdata/ldbc-v1 && mkdir -p graph params updates validation

tar --use-compress-program=unzstd -xf ~/dataset/social_network-sf${SF}-CsvComposite-LongDateFormatter.tar.zst -C graph
tar --use-compress-program=unzstd -xf ~/dataset/substitution_parameters-sf${SF}.tar.zst -C params
tar --use-compress-program=unzstd -xf ~/dataset/social_network-sf${SF}-numpart-1.tar.zst -C updates
tar --use-compress-program=unzstd -xf ~/dataset/validation_params-interactive-v1.0.0-sf0.1-to-sf10.tar.zst -C validation


sudo ./scripts/neo4j/load_dataset.sh --config none --scale-factor 1 --csv-dir /mnt/dbdata/ldbc-v1/graph/social_network-sf1-CsvComposite-LongDateFormatter
sudo ./scripts/neo4j/restore.sh --make-pristine
sudo ./scripts/neo4j/load_dataset.sh --config none --scale-factor 10 --csv-dir /mnt/dbdata/ldbc-v1/graph/social_network-sf10-CsvComposite-LongDateFormatter
sudo ./scripts/neo4j/restore.sh --make-pristine
```

To swap between dataset you have to do the following

```bash
# To sf10
sudo cp /var/lib/db-benchmark/neo4j_dataset.sf10 /var/lib/db-benchmark/neo4j_dataset
sudo ./scripts/neo4j/restore.sh
# To sf1
sudo cp /var/lib/db-benchmark/neo4j_dataset.sf1 /var/lib/db-benchmark/neo4j_dataset
sudo ./scripts/neo4j/restore.sh
```

## Propagrate the databases to other VMs

Side note: A key for remote connection has to be set between the VMs.

```bash
# The absolute keypaths and explict remote user are required
# The databases
sudo rsync -a --info=progress2 --rsync-path="sudo rsync" \
  -e "ssh -i /home/<user>/.ssh/<key> -o StrictHostKeyChecking=accept-new" \
  /mnt/dbdata/neo4j/pristine_ldbc-v1-sf1 /mnt/dbdata/neo4j/pristine_ldbc-v1-sf10 \
  <user>@<target>:/mnt/dbdata/neo4j/
# The swap files
scp -i ~/.ssh/<key> /var/lib/db-benchmark/neo4j_dataset.sf{1,10} <target>:/tmp/
ssh -i ~/.ssh/<key> <target> 'sudo mv /tmp/neo4j_dataset.sf1 /tmp/neo4j_dataset.sf10 /var/lib/db-benchmark/'
```

## Driver properties

```bash
#SF1
sudo ./scripts/neo4j/make_properties.sh --out-dir /etc/db-benchmark/sf1 \
     --updates-dir     /mnt/dbdata/ldbc-v1/updates/social_network-sf1-numpart-1 \
     --parameters-dir  /mnt/dbdata/ldbc-v1/params/substitution_parameters-sf1 \
     --validation-file /mnt/dbdata/ldbc-v1/validation/validation_params-sf1.csv

#SF10
sudo ./scripts/neo4j/make_properties.sh --out-dir /etc/db-benchmark/sf10 \
     --updates-dir     /mnt/dbdata/ldbc-v1/updates/social_network-sf10-numpart-1 \
     --parameters-dir  /mnt/dbdata/ldbc-v1/params/substitution_parameters-sf10 \
     --validation-file /mnt/dbdata/ldbc-v1/validation/validation_params-sf10.csv
```

## Validate drivers once per SF

```bash
#SF1
sudo cp /var/lib/db-benchmark/neo4j_dataset.sf1 /var/lib/db-benchmark/neo4j_dataset
sudo ./scripts/neo4j/restore.sh
/opt/ldbc-snb-interactive-v1/cypher/driver/validate.sh /etc/db-benchmark/sf1/ldbc-validate.properties

#SF10
sudo cp /var/lib/db-benchmark/neo4j_dataset.sf10 /var/lib/db-benchmark/neo4j_dataset
sudo ./scripts/neo4j/restore.sh
/opt/ldbc-snb-interactive-v1/cypher/driver/validate.sh /etc/db-benchmark/sf10/ldbc-validate.properties
```

## Calibrating TCR

You need to manually load the Dataset first

```bash
sudo ./scripts/neo4j/calibrate_tcr.sh --config snp --regime exceeding --round calibrateTCR \
  --warm-up 500 --operations 5000 --start-tcr 0.1 --out ~/raw_results
```

## Benchmark Script

```bash
#SF1
sudo ./run_benchmark.sh --config none --regime resident --round <name>_<regime> \
  --properties /etc/db-benchmark/sf1/ldbc-benchmark.properties \
  --tcr <calibrated> --operations 20000 --warmup-operations 0 \
  --reps 1 --out ~/raw_results

#SF10
sudo ./run_benchmark.sh --config none --regime exceeding --round <name>_<regime> \
  --properties /etc/db-benchmark/sf10/ldbc-benchmark.properties \
  --tcr <calibrated> --operations 20000 --warmup-operations 0 \
  --reps 1 --out ~/raw_results
```

### Reproduce our campaign with

```bash
sudo ./scripts/neo4j/campaign.sh --config none --round campaign_neo4j --out ~/raw_results
```

