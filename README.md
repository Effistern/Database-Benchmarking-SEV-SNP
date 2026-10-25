# Database-Benchmarking-SEV-SNP

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
