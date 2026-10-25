#!/bin/bash
ZONE="europe-west3-a"
DEST="./raw_results"


VMS=(
  "vm-none"
  "vm-sev"
  "vm-snp"
)

mkdir -p "$DEST"

for VM in "${VMS[@]}"; do
  echo "Downloading from ${VM}"

  gcloud compute scp --recurse \
    "${VM}:~/raw_results" \
    "./" \
    --zone="$ZONE"

  gcloud compute scp --recurse \
    "${VM}:~/env_check" \
    "$DEST/" \
    --zone="$ZONE"

done

echo "All downloads completed."
