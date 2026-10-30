#--------------------------------------------------------
#Logging
#--------------------------------------------------------
BENCH_LOG="${BENCH_LOG:-}"

lib_init() {
        [[ -n "$BENCH_LOG" ]] || {
              echo "ERROR: set BENCH_LOG=<path> before sourcing behaviour starts" >&2
              return 2
        }
        mkdir -p "$(dirname "$BENCH_LOG")"
        touch "$BENCH_LOG"
}


log () {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" |
  tee -a "$BENCH_LOG" >&2 || true
}

die () {
  log "FATAL: $*"
  exit 1
}

run() {
  "$@"
}

#--------------------------------------------------------
#Configuration and Regime validation
#--------------------------------------------------------

validate_config (){
  case "$1" in
      none|sev|snp) ;;
      "") die "--config required (none|sev|snp)" ;;
      *)  die "--config must be (none|sev|snp (got '$1')" ;;
    esac
}

validate_regime (){
  case "$1" in
    resident|exceeding) ;;
    *) die "--regime must be resident|exceeding (got '$1')" ;;
  esac

}

#--------------------------------------------------------
#Mongo Help functions
#--------------------------------------------------------

mongo_num() {
    mongosh --quiet ${2:+"$2"} --eval "$1" 2>/dev/null |
      tr -dc '0-9'
}

mongod_reachable(){
  mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1
}

require_mongod(){
  command -v mongosh >/dev/null 2>&1 ||
    die "mongosh not installed"
  mongod_reachable || die "MongoDB is not reachable"
}

wait_for_mongod(){
  for _ in {1..30}; do
        if mongod_reachable; then
          return 0
          fi
          sleep 2
      done
      die "MongoDB did not become reachable"
}

#--------------------------------------------------------
#YCSB-environment
#--------------------------------------------------------
source_ycsb_profile() {
  [[ -f /etc/profile.d/ycsb.sh ]] || die "YCSB is not installed"
  source /etc/profile.d/ycsb.sh
  [[ -x "${YCSB_HOME:-}/bin/ycsb.sh" ]] ||
    die "YCSB not installed at ${YCSB_HOME:-<unset>}"
}

#--------------------------------------------------------
#Argument parsing
#--------------------------------------------------------

arg_value() {
  printf '%s\n' "${2:?ERROR: $1 requires a value}"
}

arg_flag(){
  printf '1\n'
}

require_cmd(){
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 ||
    die "${tool} not installed"
    done
}

require_mount(){
  mountpoint -q "$1" || die "$1 is not mounted"
}

free_mb_on(){
  df -P --block-size=1M "$1" | awk 'NR==2{print $4}'
}




















