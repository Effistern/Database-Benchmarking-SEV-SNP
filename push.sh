#!/bin/bash
ZONE="europe-west3-a"
SOURCE="./scripts"
DEST="~/scripts"

VMS=(
  "vm-none"
  "vm-sev"
  "vm-snp"
)

for VM in "${VMS[@]}"; do
  echo "Uploading scripts to ${VM}"

  gcloud compute ssh "$VM" \
    --zone="$ZONE" \
    --command="rm -rf ~/scripts"

  gcloud compute scp --recurse \
    "$SOURCE" \
    "${VM}:${DEST}" \
    --zone="$ZONE"
done

echo "All upload completed."