#!/usr/bin/env bash
# 97-why-installer.sh - run ON THE PHP CONTAINER.
#
# Symptom this diagnoses:
#
#     30-install-civicrm.sh: civicrm.settings.php present - nothing to do
#     ...but https://the-site/ shows the CiviCRM Installer,
#        and /civicrm/login returns 404.
#
# Those two statements contradict each other, and the contradiction is the
# whole diagnosis. 30-install-civicrm.sh decides it is installed with a single
# test - does private/civicrm.settings.php exist. CiviCRM decides by actually
# loading that file. So the file is on disk and something about it is
# unusable. The candidates are a short list, and each wants a different fix:
#
#   * unreadable by the webserver user   -> a permissions fix, no reinstall
#   * a PHP parse error in the file      -> a corrupt file, reinstall
#   * pointing at a database that is gone -> the volume moved, reinstall
#   * written for a different document root -> paths are stale, reinstall
#
# This separates them. Read-only.
set -uo pipefail

# shellcheck source=lib.sh
_CIVI_SELF="${BASH_SOURCE[0]:-$0}"
. "$(dirname "$_CIVI_SELF")/lib.sh" || { echo "civi: cannot source lib.sh" >&2; exit 1; }

sec() { printf '\n=== %s ===\n' "$*"; }
ok()  { printf '  [ ok ] %s\n' "$*"; }
bad() { printf '  [BAD ] %s\n' "$*"; }
info(){ printf '  [info] %s\n' "$*"; }

# A diagnostic must never abort on the thing it is diagnosing, so the helpers
# that die are called defensively. detect_app_root() calls die when it cannot
# find the project root, which is exactly one of the faults being looked for -
# an earlier version of this script died on that line, one step before its first
# finding.
APP_ROOT=""
if ! APP_ROOT="$(detect_app_root 2>/dev/null)"; then
  APP_ROOT=""
fi
if [ -z "$APP_ROOT" ]; then
  # Fall back to the known layout rather than giving up.
  for d in /var/www/html /var/www/htdocs /var/www/vhosts; do
    [ -d "$d" ] && { APP_ROOT="$d"; break; }
  done
fi
SETTINGS="${APP_ROOT:-/var/www/html}/private/civicrm.settings.php"

sec "1. the document root and the settings file"
info "app root:   ${APP_ROOT}"
info "settings:   ${SETTINGS}"

if [ ! -f "$SETTINGS" ]; then
  bad "the settings file does NOT exist. 30-install-civicrm.sh must have been
    pointed at a different app root than the one CiviCRM serves.
    Run: make install TARGET=<node>"
  exit 0
fi

ls -la "$SETTINGS" | sed 's/^/  /'
SIZE="$(wc -c < "$SETTINGS" 2>/dev/null || echo 0)"
if [ "$SIZE" -lt 100 ]; then
  bad "the file is only ${SIZE} bytes - that is truncated, not a settings file"
else
  ok "${SIZE} bytes"
fi

sec "2. is it valid PHP?"
if php -l "$SETTINGS" 2>&1 | sed 's/^/  /'; then
  ok "parses cleanly"
else
  bad "PARSE ERROR above - CiviCRM cannot load this file, which is exactly
    why it falls back to the installer. Deleting it and re-running
    'make install' will regenerate it."
fi

sec "3. can the webserver user read it?"
WEB_USER=""
for c in apache2 httpd; do
  command -v "$c" >/dev/null 2>&1 || continue
  # shellcheck disable=SC1091
  [ -r /etc/apache2/envvars ] && . /etc/apache2/envvars
  u="$("$c" -t -D DUMP_RUN_CFG 2>/dev/null | awk -F'"' '/User/ {print $2; exit}')"
  [ -n "$u" ] && [ "$u" != "root" ] && WEB_USER="$u" && break
done
info "webserver user: ${WEB_USER:-unknown}"

if [ -n "$WEB_USER" ]; then
  if su -s /bin/sh -c "head -c 1 '$SETTINGS' >/dev/null" "$WEB_USER" 2>/dev/null; then
    ok "${WEB_USER} can read the settings file"
  else
    bad "${WEB_USER} CANNOT read it. CiviCRM runs as ${WEB_USER}, so it cannot
    load the settings and silently falls back to the installer.
    Fix with:  chown ${WEB_USER}:${WEB_USER} '${SETTINGS}'
    chown -R ${WEB_USER}:${WEB_USER} '${APP_ROOT}/private'
    chmod 2770 '${APP_ROOT}/private'
    (no reinstall needed)"
  fi
else
  info "could not determine the webserver user; skipping the readability test"
fi

sec "4. what does it point at?"
php -r '
$f = $argv[1];
$s = file_get_contents($f);
$get = function ($re) use ($s) { return preg_match($re, $s, $m) ? $m[1] : "(not set)"; };
printf("  cmsBaseUrl : %s\n",   $get("/cmsBaseUrl\s*=\s*.([^\x27\"]+)/"));
printf("  db server  : %s\n",   $get("/\x27server\x27\s*=>\s*.([^\x27]+)/"));
printf("  db name    : %s\n",   $get("/\x27database\x27\s*=>\s*.([^\x27]+)/"));
printf("  db user    : %s\n",   $get("/\x27username\x27\s*=>\s*.([^\x27]+)/"));
printf("  settingsPath in file  : %s\n", $get("/settingsPath\s*=\s*.([^\x27\"]+)/"));
' "$SETTINGS" 2>/dev/null | sed 's/^/  /' || info "could not parse the file"

SERVED="$(php -r '
require $argv[1];
echo defined("CIVICRM_BASE_URL") ? CIVICRM_BASE_URL : "(undefined)";
' "$SETTINGS" 2>/dev/null || echo "(could not load)")"
info "loading it in PHP yields base URL: ${SERVED}"

sec "5. is the database it points at actually there?"
DB_HOST="$(resolve_db_host)"
DB_HOST="${DB_HOST:-$(php -r '$s=file_get_contents($argv[1]);
  if (preg_match("/\x27server\x27\s*=>\s*.\x27([^\x27:]+)/", $s, $m)) echo $m[1];' "$SETTINGS" 2>/dev/null)}"
DB_USER="$(php -r '$s=file_get_contents($argv[1]);
  if (preg_match("/\x27username\x27\s*=>\s*.\x27([^\x27]+)/", $s, $m)) echo $m[1];' "$SETTINGS" 2>/dev/null)"
DB_NAME="$(php -r '$s=file_get_contents($argv[1]);
  if (preg_match("/\x27database\x27\s*=>\s*.\x27([^\x27]+)/", $s, $m)) echo $m[1];' "$SETTINGS" 2>/dev/null)"
DB_PASS="${CIVICRM_DB_PASS:-$(php -r '$s=file_get_contents($argv[1]);
  if (preg_match("/\x27password\x27\s*=>\s*.\x27([^\x27]+)/", $s, $m)) echo $m[1];' "$SETTINGS" 2>/dev/null)}"

info "db: ${DB_USER}@${DB_HOST}/${DB_NAME}"

CLI="$(command -v mariadb || command -v mysql || true)"
if [ -z "$CLI" ]; then
  info "no mysql client; skipping"
elif [ -z "$DB_HOST" ]; then
  bad "could not determine the database host from the settings file"
else
  OUT="$("$CLI" --connect-timeout=5 --protocol=TCP -h "$DB_HOST" -P "${CIVICRM_DB_PORT:-3306}" \
        -u "${DB_USER:-root}" "-p${DB_PASS}" -D "${DB_NAME}" -e 'SELECT COUNT(*) FROM civicrm_menu' 2>&1)"
  case "$OUT" in
    *[0-9]*)
      ok "connected; civicrm_menu has $(printf '%s' "$OUT" | tail -1) rows"
      N="$("$CLI" --connect-timeout=5 --protocol=TCP -h "$DB_HOST" -P "${CIVICRM_DB_PORT:-3306}" \
            -u "${DB_USER}" "-p${DB_PASS}" -D "$DB_NAME" \
            -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name LIKE 'civicrm\_%'" 2>/dev/null | tail -1)"
      info "civicrm_* tables in ${DB_NAME}: ${N:-?}"
      ;;
    *) bad "database not usable: $(printf '%s' "$OUT" | head -1)" ;;
  esac
fi

sec "verdict"
info "30-install-civicrm.sh only tests for the file's EXISTENCE."
info "CiviCRM tests whether it can LOAD it. Any of the [BAD] lines above is a"
info "reason those two disagree. The fix is named next to each one."