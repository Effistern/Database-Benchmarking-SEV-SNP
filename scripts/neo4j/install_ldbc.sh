#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------
# Variables
# -----------------------------------------------------------------

COMMIT="11db98cc2ba14c33492f6c0c34e68c8be7e22e5f"
LDBC_HOME="/opt/ldbc-snb-interactive-v1"
JDK="11"
REPO_URL="https://github.com/ldbc/ldbc_snb_interactive_v1_impls.git"
STATE="/var/lib/db-benchmark"
LOG="/var/log/ldbc_v1_install.log"

# -----------------------------------------------------------------
# Parsing
# -----------------------------------------------------------------

while (($#)); do
  case "$1" in
  --commit)
    COMMIT="${2:?Missing value for --heap-gb}"
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

log "Installing LDBC Interactive v1 into ${LDBC_HOME}"

# -----------------------------------------------------------------
# Installing requirements
# -----------------------------------------------------------------

for pkg in git maven "openjdk-${JDK}-jdk"; do
  dpkg -s "$pkg" >/dev/null 2>&1 ||
    {
      log "Installing ${pkg}"
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" ||
        die "Couldn't install ${pkg}, try manually installing."
    }
done

JAVA_HOME_DIR="/usr/lib/jvm/java-${JDK}-openjdk-amd64"
if [[ -x "$JAVA_HOME_DIR/bin/java" ]]; then
  log "Installing Openjdk-${JDK}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "openjdk-${JDK}-jdk-headless" ||
    die "Java ${JDK} was not found. Re-run install or do it manually"
fi

# -----------------------------------------------------------------
# Cloning and pining
# -----------------------------------------------------------------

if [[ -d "$LDBC_HOME/.git" ]]; then
  log "Repository already present"
  git -C "$LDBC_HOME" fetch --quiet --all
else
  log "Cloning repository"
  git clone --quiet "$REPO_URL" "$LDBC_HOME" ||
    die "Clone failed. Check connection"
fi

if [[ -n "$COMMIT" ]]; then
  git -C "$LDBC_HOME" checkout --quiet "$COMMIT" ||
    die "Could not check out ${COMMIT}"
fi

# -----------------------------------------------------------------
# Maven build
# -----------------------------------------------------------------

log "Building the cypher implementation with JDK ${JDK}"
if ! JAVA_HOME="$JAVA_HOME_DIR" mvn -q -pl cypher -am package -DskipTests \
  -f "$LDBC_HOME/pom.xml" >"$LOG.build" 2>&1; then
  tail -30 "$LOG.build"
  die "Build failed."
fi
log "Build succeeded"

JAR="$(find "$LDBC_HOME/cypher/target" -maxdepth 1 -name '*.jar' \
  ! -name '*sources*' ! -name '*javadoc*' | head -1)"

if [[ -z "$JAR" ]]; then
  die "The build succeeded but did not produce the jar needed. Try again"
fi

QUERY_COUNT="$(find "$LDBC_HOME/cypher/queries/" -maxdepth 1 -type f -name '*.cypher' 2>/dev/null | wc -l)"

{
  printf 'version=v1\n'
  printf 'ldbc_home=%s\n' "$LDBC_HOME"
  printf 'commit=%s\n' "$COMMIT"
  printf 'repo_irl=%s\n' "$REPO_URL"
  printf 'query_files=%s\n' "$QUERY_COUNT"
} >"$STATE/ldbc_install"

log "Installation done"
