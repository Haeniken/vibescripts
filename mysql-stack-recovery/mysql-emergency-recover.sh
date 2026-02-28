#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Emergency recovery without MySQL restart:
# 1) set wait/interactive timeout to low values
# 2) kill old Sleep sessions from PHP app container
# 3) raise max_connections
# 4) print runtime status
# 5) verify site HTTP 200
# 6) restore wait/interactive/max_connections defaults

# ---------------------------------------------------------------------------
# Default configuration (edit here if you want new defaults for this script)
# Environment variables can still override these values at runtime.
# ---------------------------------------------------------------------------
DEFAULT_MYSQL_CONTAINER="mysql-clients"
DEFAULT_PHP_CONTAINER="php-apache-clients"
DEFAULT_PHP_HOSTNAME="php-apache-clients"
DEFAULT_MYSQL_USER="root"
DEFAULT_MYSQL_SECRET_PATH="/run/secrets/MYSQL_ROOT_PASSWORD"

DEFAULT_SITE_URL="https://example.com/"

DEFAULT_TEMP_WAIT_TIMEOUT=30
DEFAULT_TEMP_INTERACTIVE_TIMEOUT=30
DEFAULT_TEMP_MAX_CONNECTIONS=700
DEFAULT_SLEEP_AGE_SEC=60

DEFAULT_RESTORE_WAIT_TIMEOUT=300
DEFAULT_RESTORE_INTERACTIVE_TIMEOUT=28800
DEFAULT_RESTORE_MAX_CONNECTIONS=500

DEFAULT_CURL_ATTEMPTS=3
DEFAULT_CURL_TIMEOUT_SEC=15

# Runtime values (from env or defaults above)
MYSQL_CONTAINER="${MYSQL_CONTAINER:-$DEFAULT_MYSQL_CONTAINER}"
PHP_CONTAINER="${PHP_CONTAINER:-$DEFAULT_PHP_CONTAINER}"
PHP_HOSTNAME="${PHP_HOSTNAME:-$DEFAULT_PHP_HOSTNAME}"
MYSQL_USER="${MYSQL_USER:-$DEFAULT_MYSQL_USER}"
MYSQL_SECRET_PATH="${MYSQL_SECRET_PATH:-$DEFAULT_MYSQL_SECRET_PATH}"

SITE_URL="${SITE_URL:-$DEFAULT_SITE_URL}"

TEMP_WAIT_TIMEOUT="${TEMP_WAIT_TIMEOUT:-$DEFAULT_TEMP_WAIT_TIMEOUT}"
TEMP_INTERACTIVE_TIMEOUT="${TEMP_INTERACTIVE_TIMEOUT:-$DEFAULT_TEMP_INTERACTIVE_TIMEOUT}"
TEMP_MAX_CONNECTIONS="${TEMP_MAX_CONNECTIONS:-$DEFAULT_TEMP_MAX_CONNECTIONS}"
SLEEP_AGE_SEC="${SLEEP_AGE_SEC:-$DEFAULT_SLEEP_AGE_SEC}"

RESTORE_WAIT_TIMEOUT="${RESTORE_WAIT_TIMEOUT:-$DEFAULT_RESTORE_WAIT_TIMEOUT}"
RESTORE_INTERACTIVE_TIMEOUT="${RESTORE_INTERACTIVE_TIMEOUT:-$DEFAULT_RESTORE_INTERACTIVE_TIMEOUT}"
RESTORE_MAX_CONNECTIONS="${RESTORE_MAX_CONNECTIONS:-$DEFAULT_RESTORE_MAX_CONNECTIONS}"

CURL_ATTEMPTS="${CURL_ATTEMPTS:-$DEFAULT_CURL_ATTEMPTS}"
CURL_TIMEOUT_SEC="${CURL_TIMEOUT_SEC:-$DEFAULT_CURL_TIMEOUT_SEC}"

DEFAULT_ONLY=0

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  printf '[%s] %s\n' "$(ts)" "$*"
}

debug() {
  # Keep debug on stderr so command-substitution helpers (that return data
  # via stdout) are not polluted by debug lines.
  log "DEBUG: $*" >&2
}

die() {
  log "ERROR: $*"
  exit 2
}

# ---------------------------------------------------------------------------
# CLI/help
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: mysql-emergency-recover.sh [options]

Options:
  --default             Apply only default values and exit (no checks/workflow)
  --site-url URL        URL to verify (default: https://fineart-print.ru/)
  --sleep-age-sec N     Kill Sleep sessions older than N seconds (default: 60)
  -h, --help            Show help
EOF
}

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------
require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
}

# Run SQL inside mysql container using root password from secret file.
mysql_exec() {
  local mysql_opts="$1"
  local sql="$2"

  docker exec -i \
    -e DETECTOR_MYSQL_USER="$MYSQL_USER" \
    -e DETECTOR_SECRET_PATH="$MYSQL_SECRET_PATH" \
    "$MYSQL_CONTAINER" sh -c '
set -eu
pw="$(tr -d "\r\n" < "$DETECTOR_SECRET_PATH" 2>/dev/null || true)"
[ -n "$pw" ] || { echo "cannot read MySQL secret: $DETECTOR_SECRET_PATH" >&2; exit 1; }
MYSQL_PWD="$pw" mysql '"$mysql_opts"' -u"$DETECTOR_MYSQL_USER"
' <<< "$sql"
}

mysql_table() {
  mysql_exec "-B" "$1"
}

mysql_nobatch() {
  mysql_exec "-N -B" "$1"
}

# Ensure target container is running before we start changing runtime settings.
check_container_running() {
  local name="$1"
  local state
  state="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)"
  [[ "$state" == "true" ]] || die "container is not running: $name"
}

# Build a safe HOST filter for processlist (hostname + container name + container IPs).
build_php_host_filter() {
  local ips_raw
  ips_raw="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$PHP_CONTAINER" 2>/dev/null || true)"
  debug "PHP container network IPs: ${ips_raw:-none}"

  local filters=()
  filters+=("HOST='${PHP_HOSTNAME}'")
  filters+=("HOST LIKE '${PHP_HOSTNAME}:%'")
  filters+=("HOST='${PHP_CONTAINER}'")
  filters+=("HOST LIKE '${PHP_CONTAINER}:%'")

  local ip
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    filters+=("HOST='${ip}'")
    filters+=("HOST LIKE '${ip}:%'")
  done < <(printf '%s' "$ips_raw" | tr ' ' '\n')

  local joined=""
  local f
  for f in "${filters[@]}"; do
    if [[ -z "$joined" ]]; then
      joined="$f"
    else
      joined="$joined OR $f"
    fi
  done

  echo "$joined"
}

# Print a compact state snapshot so operator can compare before/after quickly.
print_status_snapshot() {
  local title="$1"
  log "$title"
  mysql_table "
SHOW GLOBAL VARIABLES WHERE Variable_name IN ('wait_timeout','interactive_timeout','max_connections');
SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Threads_running','Max_used_connections');
SELECT SUBSTRING_INDEX(HOST,':',1) AS host_ip, COMMAND, COUNT(*) AS cnt, MAX(TIME) AS max_time_s
FROM information_schema.processlist
GROUP BY SUBSTRING_INDEX(HOST,':',1), COMMAND
ORDER BY cnt DESC
LIMIT 15;
"
}

# Real end-user validation: HTTP 200 on target site.
run_site_check() {
  local attempt=1
  local ok=0
  local last_code="000"
  local last_time="0"

  log "HTTP verification for ${SITE_URL} (need 200)"
  while (( attempt <= CURL_ATTEMPTS )); do
    local out
    out="$(curl -k -sS -o /dev/null --max-time "$CURL_TIMEOUT_SEC" -w '%{http_code} %{time_total}' "$SITE_URL" 2>/dev/null || echo '000 0')"
    last_code="${out%% *}"
    last_time="${out##* }"
    log "Attempt ${attempt}/${CURL_ATTEMPTS}: code=${last_code}, time=${last_time}s"
    if [[ "$last_code" == "200" ]]; then
      ok=1
      break
    fi
    attempt=$((attempt + 1))
    sleep 2
  done

  if (( ok == 1 )); then
    log "HTTP check passed (200)."
    return 0
  fi

  log "HTTP check did not get 200 after ${CURL_ATTEMPTS} attempts."
  return 1
}

trap 'die "Script failed at line ${LINENO}"' ERR

# ---------------------------------------------------------------------------
# CLI arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --default)
      DEFAULT_ONLY=1
      ;;
    --site-url)
      shift
      [[ $# -gt 0 ]] || die "--site-url requires a value"
      SITE_URL="$1"
      ;;
    --sleep-age-sec)
      shift
      [[ $# -gt 0 ]] || die "--sleep-age-sec requires a value"
      SLEEP_AGE_SEC="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
require_cmd docker
require_cmd awk
require_cmd tr
require_cmd date

check_container_running "$MYSQL_CONTAINER"

log "Starting emergency recovery (without MySQL restart)"
debug "mysql_container=${MYSQL_CONTAINER}, php_container=${PHP_CONTAINER}, php_hostname=${PHP_HOSTNAME}, mysql_user=${MYSQL_USER}, mysql_secret_path=${MYSQL_SECRET_PATH}"
debug "temp_timeouts wait=${TEMP_WAIT_TIMEOUT}, interactive=${TEMP_INTERACTIVE_TIMEOUT}, temp_max_connections=${TEMP_MAX_CONNECTIONS}"
debug "restore_values wait=${RESTORE_WAIT_TIMEOUT}, interactive=${RESTORE_INTERACTIVE_TIMEOUT}, max_connections=${RESTORE_MAX_CONNECTIONS}, sleep_age_sec=${SLEEP_AGE_SEC}"

# ---------------------------------------------------------------------------
# --default mode: only revert to configured defaults and exit.
# ---------------------------------------------------------------------------
if (( DEFAULT_ONLY == 1 )); then
  log "Default-only mode: applying default MySQL runtime values and exiting"
  mysql_nobatch "
SET GLOBAL wait_timeout=${RESTORE_WAIT_TIMEOUT};
SET GLOBAL interactive_timeout=${RESTORE_INTERACTIVE_TIMEOUT};
SET GLOBAL max_connections=${RESTORE_MAX_CONNECTIONS};
"
  log "Default values applied"
  exit 0
fi

require_cmd curl
check_container_running "$PHP_CONTAINER"

# ---------------------------------------------------------------------------
# Main recovery workflow
# ---------------------------------------------------------------------------
print_status_snapshot "Initial MySQL snapshot:"

# Step 1: reduce idle connection lifetime to release pool faster.
log "Step 1/6: Set temporary low timeouts"
mysql_nobatch "
SET GLOBAL wait_timeout=${TEMP_WAIT_TIMEOUT};
SET GLOBAL interactive_timeout=${TEMP_INTERACTIVE_TIMEOUT};
"
log "Step 1/6 done"

# Step 2: actively free stale idle app sessions.
log "Step 2/6: Kill old Sleep sessions from PHP app container"
php_host_filter="$(build_php_host_filter)"
debug "PHP host filter: ${php_host_filter}"

kill_ids="$(mysql_nobatch "
SELECT ID
FROM information_schema.processlist
WHERE COMMAND='Sleep'
  AND TIME > ${SLEEP_AGE_SEC}
  AND (${php_host_filter})
ORDER BY TIME DESC;
" || true)"

kill_count=0
if [[ -n "${kill_ids}" ]]; then
  kill_count="$(printf '%s\n' "$kill_ids" | awk 'NF>0{c++} END{print c+0}')"
fi
debug "Sleep session IDs to kill: ${kill_ids:-none}"
log "Sleep sessions selected for kill: ${kill_count}"

if (( kill_count > 0 )); then
  kill_sql="$(printf '%s\n' "$kill_ids" | awk 'NF>0{printf "KILL %s;\n",$1}')"
  mysql_nobatch "$kill_sql" >/dev/null
  log "Killed ${kill_count} Sleep sessions"
else
  log "No Sleep sessions matched filter"
fi
log "Step 2/6 done"

# Step 3: temporarily increase available MySQL connection headroom.
log "Step 3/6: Raise max_connections"
mysql_nobatch "SET GLOBAL max_connections=${TEMP_MAX_CONNECTIONS};"
log "Step 3/6 done"

# Step 4: operator snapshot after emergency changes.
log "Step 4/6: Status after emergency changes"
print_status_snapshot "Post-change MySQL snapshot:"
log "Step 4/6 done"

# Step 5: confirm service is reachable from HTTP standpoint.
log "Step 5/6: Real service check (HTTP)"
run_site_check || log "HTTP check failed, continuing to restore defaults anyway"
log "Step 5/6 done"

# Step 6: always return runtime values to configured defaults.
log "Step 6/6: Restore regular defaults"
mysql_nobatch "
SET GLOBAL wait_timeout=${RESTORE_WAIT_TIMEOUT};
SET GLOBAL interactive_timeout=${RESTORE_INTERACTIVE_TIMEOUT};
SET GLOBAL max_connections=${RESTORE_MAX_CONNECTIONS};
"
print_status_snapshot "Final MySQL snapshot after timeout restore:"
log "Step 6/6 done"

log "Emergency recovery workflow completed."
exit 0
