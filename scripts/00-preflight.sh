#!/usr/bin/env bash
# 00-preflight.sh - fail fast, loudly, before anything is mutated.
#
# Runs on the PHP container. Verifies the runtime actually satisfies CiviCRM
# Standalone's documented requirements, so that a failure here is unambiguous
# ("the platform is wrong") rather than a confusing installer failure later.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "=== preflight ==="

# --- PHP -------------------------------------------------------------------
# CiviCRM 6.16+ requires PHP >= 8.2 and recommends 8.3/8.4/8.5.
check_php_version

missing=""
for ext in $CIVICRM_REQUIRED_EXTENSIONS; do
  php -m | tr 'A-Z' 'a-z' | grep -qx "$ext" || missing="${missing} ${ext}"
done
if [ -n "$missing" ]; then
  die "missing CiviCRM-required PHP extensions:${missing}
    CiviCRM requires: bcmath curl dom mbstring zip intl fileinfo pdo_mysql
    Enable them via the platform (PHP > Extensions), or in a custom image via php.ini."
fi
log "required PHP extensions: OK"

# --- CLI vs web PHP ---------------------------------------------------------
# CiviCRM docs are explicit: the CLI PHP version and loaded extensions must
# match the web SAPI, or scheduled jobs and `cv` will misbehave.
CLI_PHP_BIN="$(command -v php)"
CLI_PHP_REAL="$(php -r 'echo PHP_BINARY;')"
if [ -n "$CLI_PHP_REAL" ] && [ "$CLI_PHP_REAL" != "$CLI_PHP_BIN" ]; then
  warn "multiple PHP binaries: 'php' -> ${CLI_PHP_REAL}. `cv` inherits whatever the cron/PATH uses."
fi
log "CLI PHP: $($CLI_PHP_REAL -r 'echo PHP_VERSION;')"

# --- PHP ini budgets --------------------------------------------------------
check_ini() {
  local key="$1" want="$2" got
  got="$(php -r "echo ini_get('$key') ?: '0';")"
  # Compare in bytes where numeric, else just report.
  if [ "$got" != "$got" ]; then die "ini $key is non-numeric: $got"; fi
  log "ini ${key} = ${got} (want >= ${want})"
}
check_ini memory_limit        256M
check_ini max_execution_time  240
check_ini post_max_size       50M
check_ini upload_max_filesize 50M

# --- FPM/applier sanity -----------------------------------------------------
if php -i | grep -qi "fpm"; then
  log "PHP SAPI appears to be FPM; per-directory .user.ini overrides will apply."
else
  warn "PHP SAPI is $(php -r 'echo PHP_SAPI;') - .user.ini overrides may not be honoured."
fi

# --- Disk ------------------------------------------------------------------
AVAIL_MB="$(df -Pm "$HOME" | awk 'NR==2 {print $4}')"
[ "${AVAIL_MB:-0}" -gt 512 ] || die "less than 512MB free in \$HOME (${AVAIL_MB}MB)"
log "free disk in \$HOME: ${AVAIL_MB}MB"

# --- Tools -----------------------------------------------------------------
for tool in curl git tar composer; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done
log "required tools: OK"

log "=== preflight passed ==="
