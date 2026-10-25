#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------
# Variables
# -----------------------------------------------------------------

CONFIG=""
CSV_DIR=""
SF=""
CONVERTED_DIR=""
POSTFIX="_0_0.csv"
DUMP_DIR=""
DATABASE="neo4j"
LDBC_HOME="/opt/ldbc-snb-interactive-v1"
HEADERS_TXT="$LDBC_HOME/cypher/scripts/headers.txt"
STATE="/var/lib/db-benchmark"
LOG="/var/log/load_dateset.log"
DATA_DIR="/mnt/dbdata/neo4j/data"

# -----------------------------------------------------------------
# Parsing
# -----------------------------------------------------------------

while (($#)); do
  case "$1" in
  --config)
    CONFIG="${2:?Missing value for --config}"
    shift 2
    ;;
  --csv-dir)
    CSV_DIR="${2:?Missing value for --csv-dir}"
    shift 2
    ;;
  --scale-factor)
    SF="${2:?Missing value for --scale-factor}"
    shift 2
    ;;
  *)
    echo "ERROR: Unknow argument: $1" >&2
    exit 2
    ;;
  esac
done

case "$CONFIG" in
none | sev | snp) ;;
"")
  echo "ERROR: --config required" >&2
  exit 2
  ;;
*)
  echo "ERROR: --config must be none|sev|snp" >&2
  exit 2
  ;;
esac

if [[ -z "$CSV_DIR" ]]; then
  echo "ERROR: --csv-dir required" >&2
  exit 2
fi

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

log "Loading dataset: "

# -----------------------------------------------------------------
# Functional guards
# -----------------------------------------------------------------

if [[ ! -f "$STATE/neo4j_setup" ]]; then
  die "install_neo4j.sh run required before this"
fi

if [[ ! -f "$STATE/ldbc_install" ]]; then
  die "install_ldbc.sh run required before this"
fi

JAVA_HOME_DIR="$(awk -F = '/^java_home=/{print $2; exit}' "$STATE/neo4j_setup" 2>/dev/null || true)"
if [[ -x "$JAVA_HOME_DIR/bin/java" ]]; then
  NEO4J_ENV=(env "JAVA_HOME=$JAVA_HOME_DIR" "PATH=$JAVA_HOME_DIR/bin:$PATH")
else
  NEO4J_ENV=(env)
fi

if [[ ! -d "$CSV_DIR/static" || ! -d "$CSV_DIR/dynamic" ]]; then
  die "Expected static/ and dynamic/ under {$CSV_DIR}."
fi

if [[ -z "$CONVERTED_DIR" ]]; then
  CONVERTED_DIR="$(dirname "$CSV_DIR")/converted"
fi

if [[ -n "$DUMP_DIR" ]]; then
  DUMP_DIR="$(dirname "$DATA_DIR")/dumps/ldbc-v1-sf${SF}"
fi

log "Loading SF=${SF}"
log "Vanilla CSV : ${CSV_DIR}"
log "Converted CSV: ${CONVERTED_DIR}"

# -----------------------------------------------------------------
# Converting headers
# -----------------------------------------------------------------

log "Replacing header"

rm -rf "${CONVERTED_DIR:?}"/*
mkdir -p "$CONVERTED_DIR/static" "$CONVERTED_DIR/dynamic"

MISSING_FILES=()
CONVERTED_COUNT=0

while read -r line; do
  # Skip empty lines
  if [[ -z "$line" ]]; then
    continue
  fi
  # Each line contains a filename and replacement header
  read -r -a columns <<<"$line"
  filename="${columns[0]}"
  header="${columns[1]}"
  source_file="$CSV_DIR/${filename}${POSTFIX}"
  output_file="$CONVERTED_DIR/${filename}${POSTFIX}"

  # If a file is missing -> Write it down
  if [[ ! -f "$source_file" ]]; then
    MISSING_FILES+=("${filename}${POSTFIX}")
    continue
  fi

  # Replace the first line with right header.
  {
    printf '%s\n' "$header"
    tail -n +2 "$source_file"
  } >"$output_file"
  CONVERTED_COUNT=$((CONVERTED_COUNT + 1))
done <"$HEADERS_TXT"

if ((${#MISSING_FILES[@]} > 0)); then
  die "${#MISSING_FILES[@]} expected CSV files. Wrong serializer?"
fi

log "Converted ${CONVERTED_COUNT} files"

# ---------------------------------------------------------------------------
# Capitalize headers
# ---------------------------------------------------------------------------

PLACE="$CONVERTED_DIR/static/place${POSTFIX}"
ORG="$CONVERTED_DIR/static/organisation${POSTFIX}"

if [[ -f "$PLACE" ]]; then
  sed -i \
    -e 's/|city$/|City/' \
    -e 's/|country$/|Country/' \
    -e 's/|continent$/|Continent/' \
    "$PLACE"
fi

if [[ -f "$ORG" ]]; then
  sed -i \
    -e 's/|company/|Company/' \
    -e 's/|university/|University/' \
    "$ORG"
fi

log "Capitalised headers"

# ---------------------------------------------------------------------------
# Import
# ---------------------------------------------------------------------------

C="$CONVERTED_DIR"
NODE_ARGS=()
REL_ARGS=()

add_node() {
  NODE_ARGS+=("--nodes=$1=$C/$2/$3${POSTFIX}")
}

add_relationship() {
  REL_ARGS+=("--relationships=$1=$C/$2/$3${POSTFIX}")
}

add_node "Place" "static" "place"
add_node "Organisation" "static" "organisation"
add_node "TagClass" "static" "tagclass"
add_node "Tag" "static" "tag"
add_node "Comment:Message" "dynamic" "comment"
add_node "Forum" "dynamic" "forum"
add_node "Person" "dynamic" "person"
add_node "Post:Message" "dynamic" "post"

add_relationship "IS_PART_OF" "static" "place_isPartOf_place"
add_relationship "IS_SUBCLASS_OF" "static" "tagclass_isSubclassOf_tagclass"
add_relationship "IS_LOCATED_IN" "static" "organisation_isLocatedIn_place"
add_relationship "HAS_TYPE" "static" "tag_hasType_tagclass"
add_relationship "HAS_CREATOR" "dynamic" "comment_hasCreator_person"
add_relationship "IS_LOCATED_IN" "dynamic" "comment_isLocatedIn_place"
add_relationship "REPLY_OF" "dynamic" "comment_replyOf_comment"
add_relationship "REPLY_OF" "dynamic" "comment_replyOf_post"
add_relationship "CONTAINER_OF" "dynamic" "forum_containerOf_post"
add_relationship "HAS_MEMBER" "dynamic" "forum_hasMember_person"
add_relationship "HAS_MODERATOR" "dynamic" "forum_hasModerator_person"
add_relationship "HAS_TAG" "dynamic" "forum_hasTag_tag"
add_relationship "HAS_INTEREST" "dynamic" "person_hasInterest_tag"
add_relationship "IS_LOCATED_IN" "dynamic" "person_isLocatedIn_place"
add_relationship "KNOWS" "dynamic" "person_knows_person"
add_relationship "LIKES" "dynamic" "person_likes_comment"
add_relationship "LIKES" "dynamic" "person_likes_post"
add_relationship "HAS_CREATOR" "dynamic" "post_hasCreator_person"
add_relationship "HAS_TAG" "dynamic" "comment_hasTag_tag"
add_relationship "HAS_TAG" "dynamic" "post_hasTag_tag"
add_relationship "IS_LOCATED_IN" "dynamic" "post_isLocatedIn_place"
add_relationship "STUDY_AT" "dynamic" "person_studyAt_organisation"
add_relationship "WORK_AT" "dynamic" "person_workAt_organisation"

restore_neo4j() {
  systemctl is-active --quiet neo4j || systemctl start neo4j || true
}
trap restore_neo4j EXIT

log "Stopping Neo4j"

systemctl stop neo4j
for _ in $(seq 1 30); do
  systemctl is-active --quiet neo4j || break
  sleep 1
done

rm -f "$DUMP_DIR/${DATABASE}.dump"

log "Importing node files and relationship files"

IMPORT_LOG="/var/log/neo4j_import.log"
REPORT_FILE="${LOGDIR:-/var/log/neo4j}/import.report"
mkdir -p "$(dirname "$REPORT_FILE")"
chown neo4j:neo4j "$(dirname "$REPORT_FILE")" 2>/dev/null || true

IMPORT_CMD=(neo4j-admin import --database="$DATABASE" --force --id-type=INTEGER --delimiter='|' --report-file="$REPORT_FILE")

if ! (cd / && sudo -u neo4j "${NEO4J_ENV[@]}" "${IMPORT_CMD[@]}" \
  "${NODE_ARGS[@]}" "${REL_ARGS[@]}" >>"$IMPORT_LOG" 2>&1); then
  tail -40 "$IMPORT_LOG"
  die "Neo4j-admin import failed. Check ${IMPORT_LOG}
    Rows rejected ${REPORT_FILE}"
fi

log "Import completed"
chown -R neo4j:neo4j "$(dirname "$DATA_DIR")"

log "Starting neo4j"
systemctl start neo4j

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

AUTH=(-u neo4j -p "admin")
cq() {
  cypher-shell -a bolt://127.0.0.1/7687 "${AUTH[@]}" --format plain "$@"
}

for i in $(seq 1 45); do
  if OUT_Q="$(cq "MATCH (n) RETURN count(n) AS n;" 2>&1)"; then
    break
  fi
  grep -qi "unauthorized\|authentication failure" <<<"$OUT_Q" &&
    die "Auth failed after import"
  sleep 2
  if [[ $i -eq 45 ]]; then
    die "Neo4j did not accept connection, still down?"
  fi
done

NODES="$(tail -n +2 <<<"$OUT_Q" | tr -d '[:space:]')"
RELS="$(cq "MATCH ()-[r]->() RETURN count(r) AS r;" | tail -n +2 | tr -d '[:space:]')"

if [[ ! "$NODES" =~ ^[0-9]+$ || ! "$RELS" =~ ^[0-9]+$ ]]; then
  die "Could not read counts"
fi

if ((NODES == 0 || RELS == 0)); then
  die "Import produces an empty graph"
fi

IDX="$LDBC_HOME/cypher/scripts/indices.cypher"
if [[ -f "$IDX" ]]; then
  log "Creating index from LDBC SNB v1"
  if ! cq -f "$IDX" >/dev/null 2>&1; then
    log "Index creation reported an error"
  fi
  cq "CALL db.awaitIndexes(600);" >/dev/null 2>&1 || true
else
  log "No indices cypher found"
fi

INDEX_COUNT="$(cq "SHOW INDEXES YIELD name RETURN count(*) AS n;" | tail -n +2 | tr -d '[:space:]')"
if [[ "$INDEX_COUNT" =~ ^[0-9]+$ ]]; then
  log "$INDEX_COUNT indexes present"
else
  die "Could not read index count"
fi
DATASET_ID="ldbc-v1-sf${SF}"

{
  printf 'dataset_id=%s\n' "$DATASET_ID"
  printf 'ldbc_version=v1\n'
  printf 'scale_factor=%s\n' "$SF"
  printf 'database=%s\n' "$DATABASE"
  printf 'csv_dir=%s\n' "$CSV_DIR"
  printf 'converted_dir=%s\n' "$CONVERTED_DIR"
  printf 'nodes=%s\nrelationships=%s\n' "$NODES" "$RELS"
  printf 'indexes=%s\n' "${INDEX_COUNT:-0}"
} >"$STATE/neo4j_dataset"

log "Loading data for scale-factor $SF done"
