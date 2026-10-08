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
# CiviCRM's documented minimums are 256M / 240 / 50M / 50M; 20-fetch-civicrm.sh
# raises memory_limit to 512M, so anything at or above the minimum is fine.
#
# Note the CLI reads NEITHER .user.ini (CGI/FastCGI only) NOR .htaccess php_value
# (mod_php only) - those are per-directory web-SAPI mechanisms. So these values
# are what `cv` and the cron jobs actually run under, governed by the platform's
# global php.ini. Report rather than die: the web SAPI serves requests, and a
# low CLI memory_limit does not block installation. It does mean a long import
# can pass in the browser and time out in cron.
# Normalise a php.ini shorthand (256M, 1G, 1024K) to bytes.
#
# The value goes through the environment rather than `php -r "$code" "$value"`,
# because a value like "-1" would be parsed by PHP's own CLI as an option and
# dump its usage text into the comparison.
ini_min_bytes() {
  INI_VALUE="$1" php 2>/dev/null <<'PHP'
<?php
$v = trim((string) getenv('INI_VALUE'));
if (preg_match('/^(\d+)([KMG]?)$/i', $v, $m)) {
    $n = (int) $m[1];
    switch (strtoupper($m[2])) {
        case 'K': $n *= 1024; break;
        case 'M': $n *= 1024 * 1024; break;
        case 'G': $n *= 1024 * 1024 * 1024; break;
    }
    echo $n;
}
PHP
}

check_ini() {
  local key="$1" want="$2" got got_b want_b
  got="$(php -r "echo ini_get('$key') ?: '';")"

  # -1 means "no limit", which trivially satisfies any minimum.
  if [ "$got" = "-1" ]; then
    log "ini ${key} = unlimited (>= ${want})"
    return 0
  fi

  got_b="$(ini_min_bytes "$got")"
  want_b="$(ini_min_bytes "$want")"

  if [ -z "$got_b" ] || [ -z "$want_b" ]; then
    log "ini ${key} = ${got:-<unset>} (want >= ${want})"
    return 0
  fi

  if [ "$got_b" -ge "$want_b" ]; then
    log "ini ${key} = ${got} (>= ${want})"
  elif [ "$key" = "memory_limit" ]; then
    warn "ini ${key} = ${got}, CiviCRM wants >= ${want}. Long imports may fail.
    The web SAPI gets 512M from .user.ini/.htaccess; the CLI SAPI follows the
    platform's global php.ini, so cv and cron keep the lower value."
  else
    warn "ini ${key} = ${got}, CiviCRM wants >= ${want}."
  fi
}
check_ini memory_limit        256M
check_ini max_execution_time  240
check_ini post_max_size       50M
check_ini upload_max_filesize 50M

# --- SAPI reporting ---------------------------------------------------------
# Decides which of the two ini mechanisms 20-fetch-civicrm.sh actually uses:
#   fpm/fcgi -> .user.ini    |    mod_php -> .htaccess php_value
log "PHP SAPI: $(php -r 'echo PHP_SAPI;')"
case "$(php -r 'echo PHP_SAPI;')" in
  fpm|fpm-fcgi|cgi-fcgi)
    log "FPM/CGI: .user.ini in the project root is the effective override." ;;
  apache2handler|apache)
    log "mod_php: the .htaccess php_value block is the effective override." ;;
  *)
    warn "unusual SAPI - neither .user.ini nor .htaccess php_value is guaranteed to apply." ;;
esac

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
