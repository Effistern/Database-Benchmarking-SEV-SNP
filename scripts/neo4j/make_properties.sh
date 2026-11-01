#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------
# Variables
# -----------------------------------------------------------------

SF=""
USERNAME="neo4j"
PASSWORD="admin"
ENDPOINT="bolt://127.0.0.1:7687"
OUT_DIR="/etc/db-benchmark"
UPDATES_DIR=""
PARAMETERS_DIR=""
VALIDATION_FILE=""
LDBC_HOME="/opt/ldbc-snb-interactive-v1"
STATE="/var/lib/db-benchmark"
LOG="/var/log/neo4j_properties.log"
TIME_UNIT="MICROSECONDS"

# -----------------------------------------------------------------
# Parsing
# -----------------------------------------------------------------

while (($#)); do
  case "$1" in
  --updates-dir)
    UPDATES_DIR="${2:?Missing value for --updates-dir}"
    shift 2
    ;;
  --parameters-dir)
    PARAMETERS_DIR="${2:?Missing value for --parameters-dir}"
    shift 2
    ;;
  --validation-file)
    VALIDATION_FILE="${2:?Missing value for --validatrion-file}"
    shift 2
    ;;
  --out-dir)
    OUT_DIR="${2:?Missing value for --out-dir}"
    shift 2
    ;;
  *)
    echo "ERROR: Unknow argument: $1" >&2
    exit 2
    ;;
  esac
done

# -----------------------------------------------------------------
# Helper
# -----------------------------------------------------------------

log() {
  echo "[$(date -u +%H:%M:%SZ)] $*" | tee -a "$LOG"
}

die() {
  log "ERROR: $*"
  exit 1
}

mkdir -p "$STATE"
touch "$LOG"

log "Creating properties"

# -----------------------------------------------------------------
# Guards
# -----------------------------------------------------------------

if [[ ! -f "$STATE/ldbc_install" ]]; then
  die "install_ldbc.sh run required before this"
fi

DRIVER_DIR="$LDBC_HOME/cypher/driver"
if [[ ! -d "$DRIVER_DIR" ]]; then
  die "Driver dir not found"
fi

if [[ -z "$SF" ]]; then
  if [[ -f "$STATE/neo4j_dataset" ]]; then
    SF="$(awk -F= '/^scale_factor=/{print $2}' "$STATE/neo4j_dataset" 2>/dev/null || true)"
  fi
fi

if [[ -z "$UPDATES_DIR" ]]; then
  if [[ -f "$STATE/neo4j_dataset" ]]; then
    CSV_REC="$(awk -F = '/^csv_dir=/{print $2; exit}' \
      "$STATE/neo4j_dataset" 2>/dev/null || true)"
    if [[ -n "$CSV_REC" && -d "$(dirname "$CSV_REC")/update-streams" ]]; then
      UPDATES_DIR="$(dirname "$CSV_REC")/update-streams"
    fi
  fi
  if [[ -z "$UPDATES_DIR" ]]; then
    die "Can't determine update-streams"
  fi
fi

shopt -s nullglob
UPD_FILES=("$UPDATES_DIR"/updateStream_*.csv)
N_UPD="${#UPD_FILES[@]}"
if ((N_UPD <= 0)); then
  die "No updateStream csv found"
fi

log " ${N_UPD} update stream files found"

if [[ -z "$PARAMETERS_DIR" ]]; then
  die " Parameters dir required"
fi
PARAMS_DIR="$PARAMETERS_DIR"
PARAM_FILES=("$PARAMS_DIR"/*)
N_PARAMS="${#PARAM_FILES[@]}"
if ((N_PARAMS <= 0)); then
  die "No substitution parameters found"
fi

log " ${N_PARAMS} parameter files found"

if [[ -n "$VALIDATION_FILE" ]]; then
  VALIDATION_PARAMS="$VALIDATION_FILE"
  VALIDATION_SOURCE="external reference"
else
  VALIDATION_PARAMS="$OUT_DIR/validation_params.csv"
  VALIDATION_SOURCE="generated here (self-referential)"
fi

log "Validation: ${VALIDATION_SOURCE} ${VALIDATION_PARAMS}"

QUERY_DIR="$LDBC_HOME/cypher/queries"
QUERIES=("$QUERY_DIR"/*.cypher)

if ((${#QUERIES[@]} <= 0)); then
  die "No cypher queries found"
fi

log "${#QUERIES[@]} queries found"

mapfile -t TEMPLATES < <(
  find "$DRIVER_DIR" -maxdepth 1 -type f -name '*.properties' | sort
)

if ((${#TEMPLATES[@]} <= 0)); then
  die "No *.properties found"
fi

set_prop() {
  local file="$1" key="$2" value="$3" esc
  esc="$(printf '%s' "$key" | sed 's/[.[\*^$]/\\&/g')"
  if grep -qE "^[[:space:]]*${esc}[[:space:]]*=" "$file"; then
    sed -i -E "s|^[[:space:]]*${esc}[[:space:]]*=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

OWNER="${SUDO_USER:-root}"
log "Owner : ${OWNER}"

mkdir -p "$OUT_DIR"
chown "$OWNER" "$OUT_DIR"
chmod 755 "$OUT_DIR"
FILE_OUT=""

for template in "${TEMPLATES[@]}"; do
  base="$(basename "$template")"
  OUT="$OUT_DIR/ldbc-${base}"
  cp -a "$template" "$OUT"
  set_prop "$OUT" "queryDir" "${LDBC_HOME}/cypher/queries"
  set_prop "$OUT" "time_unit" "$TIME_UNIT"
  set_prop "$OUT" "endpoint" "$ENDPOINT"
  set_prop "$OUT" "user" "$USERNAME"
  set_prop "$OUT" "password" "$PASSWORD"
  set_prop "$OUT" "ldbc.snb.interactive.scale_factor" "$SF"
  set_prop "$OUT" "validate_database" "$VALIDATION_PARAMS"
  set_prop "$OUT" "ldbc.snb.interactive.updates_dir" "$UPDATES_DIR"
  set_prop "$OUT" "ldbc.snb.interactive.parameters_dir" "$PARAMS_DIR"

  chown "root:$(id -gn "$OWNER")" "$OUT" 2>/dev/null || true
  chmod 640 "$OUT" 2>/dev/null || true true

  if [[ "$base" == "benchmark.properties" ]]; then
    FILE_OUT="$OUT"
  fi
done

{
  printf 'benchmark_properties=%s\n' "$FILE_OUT"
  printf 'ldbc_version=v1\n'
  printf 'properties_dir=%s\n' "$OUT_DIR"
  printf 'validation_params=%s\n' "$VALIDATION_PARAMS"
  printf 'validation_source=%s\n' "$VALIDATION_SOURCE"
  printf 'scale_factor=%s\n' "$SF"
  printf 'endpoint=%s\n' "$ENDPOINT"
} >"$STATE/ldbc_properties"

log "Creating properties done"
