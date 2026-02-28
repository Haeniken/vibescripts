#!/usr/bin/env bash
set -u

# Ultra-fast detector focused on the observed outage pattern:
# 1) Apache worker pool saturation
# 2) MySQL pressure / slow response
# 3) Nginx upstream timeouts
#
# Exit codes:
#   0 - no incident
#   1 - incident detected
#   2 - detector internal error

NGINX_CONTAINER="${NGINX_CONTAINER:-nginx-clients}"
PHP_CONTAINER="${PHP_CONTAINER:-php-apache-clients}"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-mysql-clients}"

MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_SECRET_IN_CONTAINER="${MYSQL_SECRET_IN_CONTAINER:-/run/secrets/MYSQL_ROOT_PASSWORD}"
MYSQL_PASS_FILE="${MYSQL_PASS_FILE:-}" # optional host fallback

DOCKER_TIMEOUT_SEC="${DOCKER_TIMEOUT_SEC:-6}"
MYSQL_TIMEOUT_SEC="${MYSQL_TIMEOUT_SEC:-3}"
LOCK_FILE="${LOCK_FILE:-/tmp/db-hang-detector.lock}"

APACHE_SAT_PCT_THRESHOLD="${APACHE_SAT_PCT_THRESHOLD:-95}"
APACHE_WORKERS_ABS_THRESHOLD="${APACHE_WORKERS_ABS_THRESHOLD:-220}"
MYSQL_CONN_PCT_THRESHOLD="${MYSQL_CONN_PCT_THRESHOLD:-70}"
MYSQL_QUERY_MS_THRESHOLD="${MYSQL_QUERY_MS_THRESHOLD:-1200}"

NGINX_LOOKBACK_SEC="${NGINX_LOOKBACK_SEC:-60}"
NGINX_TIMEOUTS_THRESHOLD="${NGINX_TIMEOUTS_THRESHOLD:-10}"

DEBUG=0
FULL=0

safe_int() {
  local v="${1:-0}"
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "$v"
  else
    echo "0"
  fi
}

run_docker() {
  timeout "${DOCKER_TIMEOUT_SEC}s" "$@"
}

debug() {
  if (( DEBUG == 1 )); then
    echo "DEBUG: $*"
  fi
}

usage() {
  cat <<'EOF'
Usage: db-hang-detector-secret.sh [--debug] [--full]
  --debug  Print detailed step-by-step checks and values
  --full   Run all checks even if early checks are healthy
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

mysql_exec() {
  local sql="$1"

  # Host-file fallback if explicitly provided/readable.
  if [[ -n "${MYSQL_PASS_FILE}" && -r "${MYSQL_PASS_FILE}" ]]; then
    local host_pass
    host_pass="$(tr -d '\r\n' < "${MYSQL_PASS_FILE}")"
    [[ -z "${host_pass}" ]] && return 42
    timeout "${MYSQL_TIMEOUT_SEC}s" \
      docker exec -e MYSQL_PWD="${host_pass}" "$MYSQL_CONTAINER" \
      mysql -N -B -u"$MYSQL_USER" -e "$sql"
    return $?
  fi

  timeout "${MYSQL_TIMEOUT_SEC}s" docker exec \
    -e DETECTOR_SQL="$sql" \
    -e DETECTOR_MYSQL_USER="$MYSQL_USER" \
    -e DETECTOR_SECRET_PATH="$MYSQL_SECRET_IN_CONTAINER" \
    "$MYSQL_CONTAINER" sh -lc '
pw="$(cat "$DETECTOR_SECRET_PATH" 2>/dev/null | tr -d "\r\n")"
[ -z "$pw" ] && exit 42
MYSQL_PWD="$pw" mysql -N -B -u"$DETECTOR_MYSQL_USER" -e "$DETECTOR_SQL"
'
}

if ! command -v docker >/dev/null 2>&1; then
  die "docker command not found"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      DEBUG=1
      ;;
    --full)
      FULL=1
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

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE" || true
  flock -n 9 || exit 0
fi

debug "mode full=${FULL} debug=${DEBUG}"
debug "containers nginx=${NGINX_CONTAINER} php=${PHP_CONTAINER} mysql=${MYSQL_CONTAINER}"
debug "thresholds apache_sat_pct>=${APACHE_SAT_PCT_THRESHOLD} mysql_conn_pct>=${MYSQL_CONN_PCT_THRESHOLD} mysql_q_ms>=${MYSQL_QUERY_MS_THRESHOLD} nginx_timeouts>=${NGINX_TIMEOUTS_THRESHOLD}/${NGINX_LOOKBACK_SEC}s"

# Step 1 (fast): Apache saturation
apache_raw="$(run_docker docker exec "$PHP_CONTAINER" sh -lc '
mw="$(awk "/^[[:space:]]*MaxRequestWorkers[[:space:]]+[0-9]+/{print \$2; exit}" /etc/apache2/mods-enabled/mpm_prefork.conf 2>/dev/null)"
if [ -z "$mw" ] || [ "$mw" -eq 0 ] 2>/dev/null; then
  mw="$(apache2ctl -t -D DUMP_RUN_CFG 2>/dev/null | awk "/MaxRequestWorkers:/{print \$2; exit}")"
fi
[ -z "$mw" ] && mw=0
wc="$(ps -eo comm,args | awk "/apache2 -DFOREGROUND/{n++} END{if(n>0)n--; print n+0}")"
echo "$mw $wc"
' 2>/dev/null || true)"

max_workers=0
apache_workers=0
read -r max_workers apache_workers <<< "${apache_raw:-0 0}"
max_workers="$(safe_int "$max_workers")"
apache_workers="$(safe_int "$apache_workers")"

apache_sat_pct=0
if (( max_workers > 0 )); then
  apache_sat_pct=$((apache_workers * 100 / max_workers))
fi

apache_saturated=0
if (( max_workers > 0 && apache_sat_pct >= APACHE_SAT_PCT_THRESHOLD )); then
  apache_saturated=1
elif (( max_workers == 0 && apache_workers >= APACHE_WORKERS_ABS_THRESHOLD )); then
  apache_saturated=1
fi

debug "step1 apache max_workers=${max_workers} apache_workers=${apache_workers} apache_sat_pct=${apache_sat_pct} saturated=${apache_saturated}"

if (( apache_saturated == 0 && FULL == 0 )); then
  debug "early-exit: apache not saturated"
  exit 0
fi

# Step 2 (fast): MySQL pressure in a single query
mysql_start_ms="$(date +%s%3N)"
mysql_raw="$(mysql_exec "SHOW GLOBAL VARIABLES LIKE 'max_connections';
SHOW GLOBAL STATUS LIKE 'Threads_connected';
SHOW GLOBAL STATUS LIKE 'Max_used_connections';" 2>/dev/null || true)"
mysql_end_ms="$(date +%s%3N)"
mysql_query_ms=$((mysql_end_ms - mysql_start_ms))

max_connections=0
threads_connected=0
max_used_connections=0

if [[ -n "${mysql_raw}" ]]; then
  while IFS=$'\t' read -r key value; do
    case "$key" in
      max_connections) max_connections="$(safe_int "$value")" ;;
      Threads_connected) threads_connected="$(safe_int "$value")" ;;
      Max_used_connections) max_used_connections="$(safe_int "$value")" ;;
    esac
  done <<< "$mysql_raw"
fi

mysql_conn_pct=0
if (( max_connections > 0 )); then
  mysql_conn_pct=$((threads_connected * 100 / max_connections))
fi

mysql_bad=0
if [[ -z "${mysql_raw}" ]]; then
  mysql_bad=1
elif (( mysql_query_ms >= MYSQL_QUERY_MS_THRESHOLD )); then
  mysql_bad=1
elif (( max_connections > 0 && (mysql_conn_pct >= MYSQL_CONN_PCT_THRESHOLD || max_used_connections >= max_connections) )); then
  mysql_bad=1
fi

debug "step2 mysql max_connections=${max_connections} threads_connected=${threads_connected} max_used_connections=${max_used_connections} mysql_conn_pct=${mysql_conn_pct} mysql_q_ms=${mysql_query_ms} bad=${mysql_bad}"

if (( mysql_bad == 0 && FULL == 0 )); then
  debug "early-exit: mysql pressure not confirmed"
  exit 0
fi

# Step 3: nginx confirmation (required)
nginx_timeouts_raw="$(run_docker docker logs --since "${NGINX_LOOKBACK_SEC}s" "$NGINX_CONTAINER" 2>&1 | grep -c 'upstream timed out' || true)"
nginx_timeouts="$(safe_int "$nginx_timeouts_raw")"
nginx_bad=0
if (( nginx_timeouts >= NGINX_TIMEOUTS_THRESHOLD )); then
  nginx_bad=1
fi
debug "step3 nginx timeouts_${NGINX_LOOKBACK_SEC}s=${nginx_timeouts} bad=${nginx_bad}"

incident=0
if (( apache_saturated == 1 && mysql_bad == 1 && nginx_bad == 1 )); then
  incident=1
fi

if (( incident == 0 )); then
  debug "result=OK (triple confirmation not met)"
  exit 0
fi

printf 'DB_HANG_DETECTED apache_workers=%s/%s apache_sat_pct=%s mysql_conn=%s/%s mysql_conn_pct=%s mysql_q_ms=%s nginx_timeouts_%ss=%s\n' \
  "$apache_workers" "$max_workers" "$apache_sat_pct" "$threads_connected" "$max_connections" "$mysql_conn_pct" "$mysql_query_ms" "$NGINX_LOOKBACK_SEC" "$nginx_timeouts"
exit 1
