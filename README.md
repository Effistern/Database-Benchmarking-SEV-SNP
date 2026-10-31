# Database-Benchmarking-SEV-SNP

Scripts and instructions used for our paper: *Performance Evaluation of Confidential Virtual Machines on Google Cloud:
A Benchmark of MongoDB, Neo4j and PostgreSQL Workloads under AMD SEV and SEV-SNP.*

We ran YCSB workloads A to F for MongoDB, LDBC SNB Interactive v1 for Neo4j and HammerDB TPROC-C and -H for PostgreSQL
on three Google Cloud `n2d-standard-4` instances.

BVM: baseline VM without memory encryption (`vm-none`) <br>
SEV: Using AMD SEV (`vm-sev`) <br>
SNP: Using AMD SEV, SEV-ES and SEV-SNP (`vm-snp`) <br>

## Repository layout
| Path                                                               | Content                                                                              |
|--------------------------------------------------------------------|--------------------------------------------------------------------------------------|
| `push.sh`, `pull.sh`                                               | Pushes and pulls the scripts using gcloud cli                                        |
| `instructions/`                                                    | Instructions on how to use the scripts                                               |
| `scripts/provision/`                                               | Prepares a VM (stop backgrounds services), records the environment and compares them |
| `scripts/storage`                                                  | Fio baseline and block-size sweep scripts                                            |
| `scripts/common`                                                   | Shared helpers, os-metric summary, cpu microbenchmark                                |
| `scripts/mongodb`,<br/> `scripts/neo4j`,<br/> `scripts/postgresql` | Install, load, benchmark and campaign scripts                                        |
| `scripts/analysis`                                                 | Exports the runs as CSV, builds the figures and some of tables                       |

## Running the benchmarks

The scripts all require `sudo` priviledges. The files under `ìnstructions` list the commands.
Every path was written by from the root level of the repository.

1. Create the VMs with the commands below and copy the scripts on to them using `./push.sh`
2. Prepare each VM and check their environment, following  [instructions/provision.md](instructions/provision.md)
3. Do the storage baseline on each VM, following [instructions/storage.md](instructions/storage.md)
4. For each database, on each VM follow the scripts from [MongoDB](instructions/mongodb.md), [PostgreSQL](instructions/postgresql.md) and [Neo4j](instructions/neo4j.md) respectively.
5. Download the results using `./pull.sh`

## Data

Campaign data is supposed to end up in `./scripts/analysis/campaign_data`, as this is the place the analysis scripts 
look for.

## Rebuilding the tables and figures

To build the tables numpy, scipy and matplotlib are required.

```bash
python scripts/analysis/compute_overheads.py
python scripts/analysis/make_figures.py
```

`compute_overheads.py` pairs the runs and does the statistical analysis and writes the results as LaTeX tables and the numbers as CSV.
`make_figures.py` takes the previously summarized and calculated CSV and draws figures from those.

## Notes on the code

The scripts were cleaned up and a few bugs have been fixed after the campaign.
Therefore, the results are not completely equal. The important values still get delivered the same way though.

## Google cloud commands we used to create the virtual machines

```bash
# CREATE SNP

gcloud compute instances create vm-snp \
  --zone=europe-west3-a \
  --machine-type=n2d-standard-4 \
  --image=ubuntu-2404-noble-amd64-v20260807 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=30GB \
  --boot-disk-type=pd-ssd \
  --boot-disk-interface=NVME \
  --create-disk=name=vm-snp-dbdata,size=130GB,type=pd-ssd,device-name=dbdata,auto-delete=yes,interface=NVME \
  --confidential-compute-type=SEV_SNP \
  --maintenance-policy=TERMINATE

# CREATE SEV

gcloud compute instances create vm-sev \
  --zone=europe-west3-a \
  --machine-type=n2d-standard-4 \
  --image=ubuntu-2404-noble-amd64-v20260807 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=30GB \
  --boot-disk-type=pd-ssd \
  --boot-disk-interface=NVME \
  --create-disk=name=vm-sev-dbdata,size=130GB,type=pd-ssd,device-name=dbdata,auto-delete=yes,interface=NVME \
  --confidential-compute-type=SEV \
  --maintenance-policy=TERMINATE

# CREATE NONE

gcloud compute instances create vm-none \
  --zone=europe-west3-a \
  --machine-type=n2d-standard-4 \
  --image=ubuntu-2404-noble-amd64-v20260807 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=30GB \
  --boot-disk-type=pd-ssd \
  --create-disk=name=vm-none-dbdata,size=130GB,type=pd-ssd,device-name=dbdata,auto-delete=yes \
  --maintenance-policy=TERMINATE
```
