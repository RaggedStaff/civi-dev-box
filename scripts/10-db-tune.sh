#!/usr/bin/env bash
# 10-db-tune.sh - run ON THE MARIADB CONTAINER.
#
# CiviCRM's documented database requirements (installation requirements page):
#   * utf8mb4 (recommended)
#   * thread_stack >= 192k
#   * triggers enabled
#   * ANSI / ANSI_QUOTES must NOT be in sql_mode
#   * ONLY_FULL_GROUP_BY should be OFF
#   * log_bin_trust_function_creators=1 if binary logging is on
#
# These are written to /etc/my.cnf.d/custom.cnf, which Jelastic includes from
# /etc/my.cnf and which is the documented place for user overrides that
# survive redeploy.
set -euo pipefail
# shellcheck source=lib.sh
_CIVI_SELF="${BASH_SOURCE[0]:-$0}"
. "$(dirname "$_CIVI_SELF")/lib.sh" || {
  echo "civi: cannot source lib.sh (looked next to '${_CIVI_SELF}')" >&2
  echo "civi: run this script as a FILE - piping it into 'bash -s' leaves BASH_SOURCE unset." >&2
  echo "civi: JPS hooks must use: curl -fsS <url> -o \$d/NAME.sh && bash \$d/NAME.sh" >&2
  exit 1
}

log "=== db tune ==="

: "${CIVICRM_DB_NAME:=civicrm}"
: "${CIVICRM_DB_USER:=civicrm}"
: "${CIVICRM_DB_PASS:=}"
[ -n "$CIVICRM_DB_PASS" ] || die "CIVICRM_DB_PASS must be provided"

CONF_DIR="/etc/my.cnf.d"
CONF="${CONF_DIR}/custom.cnf"
mkdir -p "$CONF_DIR"

# CiviCRM needs to create triggers and (optionally) stored routines. When the
# binary log is on, MariaDB refuses those unless creators are trusted.
cat > "$CONF" <<EOF
# Managed by civi-dev-box (10-db-tune.sh) - do not edit by hand.
[mysqld]
character-set-server        = utf8mb4
collation-server            = utf8mb4_unicode_ci
thread_stack                = 262144
sql_mode                    = STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
log_bin_trust_function_creators = 1
skip-log-bin

[client]
default-character-set       = utf8mb4
EOF

log "wrote ${CONF}"

# Apply the character-set / thread_stack changes to the running server too.
# sql_mode is applied session-wide below so it takes effect immediately without
# needing privileged access to set GLOBAL.
if command -v mariadb >/dev/null 2>&1; then MYSQL_CLI=mariadb; else MYSQL_CLI=mysql; fi

root_sql() {
  "$MYSQL_CLI" -u root ${CIVICRM_MYSQL_ROOT_PASSWORD:+-p"$CIVICRM_MYSQL_ROOT_PASSWORD"} "$@"
}

root_sql -e "SET GLOBAL sql_mode='STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';"

# --- Application database + user ------------------------------------------
# Credentials are supplied (not generated) by the manifest so that the PHP
# container can use the exact same values without cross-node plumbing.
root_sql <<SQL
CREATE DATABASE IF NOT EXISTS \`${CIVICRM_DB_NAME}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${CIVICRM_DB_USER}'@'%' IDENTIFIED BY '${CIVICRM_DB_PASS}';
ALTER USER '${CIVICRM_DB_USER}'@'%' IDENTIFIED BY '${CIVICRM_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${CIVICRM_DB_NAME}\`.* TO '${CIVICRM_DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

# --- Verify the invariants CiviCRM actually checks at install time ---------
FAILED=0
assert_sql_mode() {
  local mode; mode="$(root_sql -N -B -e 'SELECT @@GLOBAL.sql_mode;' 2>/dev/null || echo '')"
  log "sql_mode = ${mode}"
  case ",${mode}," in
    *,ONLY_FULL_GROUP_BY,*) warn "ONLY_FULL_GROUP_BY is ON; CiviCRM recommends turning it off"; FAILED=1 ;;
  esac
  case ",${mode}," in
    *,ANSI,*)        warn "ANSI is present in sql_mode; CiviCRM does not support it"; FAILED=1 ;;
    *,ANSI_QUOTES,*) warn "ANSI_QUOTES is present in sql_mode; CiviCRM does not support it"; FAILED=1 ;;
  esac
  [ "$FAILED" -eq 0 ] && log "sql_mode: OK"
}

assert_thread_stack() {
  local v; v="$(root_sql -N -B -e 'SELECT @@thread_stack;' 2>/dev/null || echo 0)"
  log "thread_stack = ${v}"
  [ "$v" -ge 196608 ] || warn "thread_stack (${v}) is below CiviCRM's 192k minimum"
}

assert_charset() {
  local cs; cs="$(root_sql -N -B -e 'SELECT @@character_set_server;' 2>/dev/null || echo '')"
  log "character_set_server = ${cs}"
  [ "$cs" = "utf8mb4" ] || warn "server charset is ${cs}, utf8mb4 recommended"
}

assert_timezone_data() {
  # CiviCRM uses CONVERT_TZ() for scheduled reminders; missing tz tables is a
  # very common silent failure.
  local out
  out="$(root_sql -N -B -e "SELECT CONVERT_TZ('2001-02-03 04:05:00','GMT','America/New_York');" 2>/dev/null || true)"
  if [ -z "$out" ] || [ "$out" = "NULL" ]; then
    warn "MySQL timezone tables appear to be empty; scheduled reminders may misbehave."
    log "  fix: mysql_tzinfo_to_sql /usr/share/mysql/zoneinfo | mysql -u root mysql"
  else
    log "timezone tables: OK (${out})"
  fi
}

assert_sql_mode
assert_thread_stack
assert_charset
assert_timezone_data

log "=== db tune complete ==="
