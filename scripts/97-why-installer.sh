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
  # Check the mode bits directly rather than shelling in as the user. An earlier
  # version used `su`, and reported "www-data CANNOT read it" for a file that
  # was -rw-rw-r--, because su failed for an unrelated reason (no login shell).
  # That sent the reader after a permissions problem that did not exist.
  MODE="$(stat -c '%A' "$SETTINGS" 2>/dev/null)"
  OTHERS="${MODE: -1}"
  GROUP="${MODE: -4:1}"
  OWNER_R="${MODE:0:1}"
  OWNER="$(stat -c '%U' "$SETTINGS" 2>/dev/null)"

  if [ "$OWNER" = "$WEB_USER" ] && [ "$OWNER_R" != "-" ]; then
    ok "${WEB_USER} owns it (${MODE})"
  elif [ "$GROUP" != "-" ]; then
    ok "group-readable (${MODE})"
  elif [ "$OTHERS" != "-" ]; then
    ok "world-readable (${MODE}) - ${WEB_USER} can read it"
  else
    bad "${MODE} with owner ${OWNER}: ${WEB_USER} cannot read it.
    Fix with:  chown -R ${WEB_USER}:${WEB_USER} '${APP_ROOT}/private'
    chmod -R u+rwX,g+rwX '${APP_ROOT}/private'; chmod 2770 '${APP_ROOT}/private'"
  fi
else
  info "could not determine the webserver user; check section 6 instead"
fi

sec "4. what does it point at?"
# Via read-settings.php, which parses $civicrm_setting['k'] = v with the PHP
# tokenizer. An inline regex reported every value as "(not set)" on a perfectly
# good file - twice - because the values are arbitrary strings and the quoting
# did not survive the trip through the shell.
# The parser is fetched here rather than up front, and failing to get it is not
# fatal. An earlier version required it before section 1, so a missing parser
# aborted the whole diagnostic - including the checks that do not need it, like
# "the settings file does not exist".
PARSER="$(dirname "${_CIVI_SELF}")/read-settings.php"
if [ ! -f "$PARSER" ]; then
  PARSER="/tmp/civi-read-settings.php"
  BASE="${CIVICRM_SCRIPTS_BASE_URL:-https://raw.githubusercontent.com/RaggedStaff/civi-dev-box/main/scripts}"
  curl -fsS "${BASE}/read-settings.php" -o "$PARSER" 2>/dev/null \
    || command -v wget >/dev/null 2>&1 && wget -qO "$PARSER" "${BASE}/read-settings.php" 2>/dev/null \
    || PARSER=""
  [ -f "$PARSER" ] || PARSER=""
fi

VALUES=""
if [ -n "$PARSER" ]; then
  VALUES="$(php "$PARSER" "$SETTINGS" 2>/dev/null)" || VALUES=""
fi
if [ -z "$PARSER" ]; then
  warn "could not obtain read-settings.php, so sections 4 and 8 are skipped.
    Fetch it from the repository into the same directory to get them."
elif [ -z "$VALUES" ] || [ "$VALUES" = "[]" ]; then
  bad "could not read \$civicrm_setting entries out of the file.
    If it parses as PHP but yields nothing, it is probably not a CiviCRM
    settings file, or it is a truncated write."
else
  printf '%s\n' "$VALUES" | sed 's/^/  /'
fi

sec "5. can PHP actually EXECUTE the file?"
# `php -l` only checks syntax. The file may parse and still fatal at runtime on
# a function or class that the current release code no longer provides - which
# is exactly what happens when the release is re-fetched over an older install.
if php -d display_errors=1 -d error_reporting=E_ALL \
     -r 'require $argv[1]; echo "loaded without error\n";' "$SETTINGS" >/tmp/_se.out 2>/tmp/_se.err; then
  ok "executed cleanly"
  sed 's/^/    /' /tmp/_se.out | grep -v '^ *$' || true
else
  bad "the file FALS to execute:"
  sed 's/^/    /' /tmp/_se.err | head -15
fi
rm -f /tmp/_se.out /tmp/_se.err

sec "6. is every directory on the path traversable by the webserver user?"
for d in / /var /var/www /var/www/html "$(dirname "$SETTINGS")"; do
  [ -d "$d" ] || continue
  PERM="$(stat -c '%A %U:%G' "$d" 2>/dev/null)"
  X="$(stat -c '%A' "$d" 2>/dev/null)"
  case "$X" in
    ?????x???) ok "${d}  ${PERM}" ;;
    *) bad "${d}  ${PERM}  <- webserver cannot traverse into this" ;;
  esac
done

sec "7. what does Apache actually log when the page is requested?"
# The most direct evidence available: make the request the browser makes, then
# read what PHP said. Any fatal error in loading the settings lands here.
PORT="$(listening_ports | awk '$1==80||$1==8080||$1==8000 {print $1; exit}')"
if [ -z "$PORT" ]; then
  bad "nothing is listening on 80/8080/8000 - run 15-start-web.sh first"
else
  ERRLOG=""
  for f in /var/log/apache2/error.log /var/log/httpd/error_log; do [ -f "$f" ] && ERRLOG="$f" && break; done

  : > "${ERRLOG:-/dev/null}" 2>/dev/null || true
  MARK="$(wc -l < "$ERRLOG" 2>/dev/null || echo 0)"
  CODE="$(curl -s -o /tmp/_page.html -w '%{http_code}' --max-time 20 "http://127.0.0.1:${PORT}/" 2>/dev/null)"
  info "GET / returned ${CODE}"

  if [ -n "$ERRLOG" ] && [ -r "$ERRLOG" ]; then
    TAILN="$(tail -n "+$((MARK + 1))" "$ERRLOG" 2>/dev/null | grep -vE 'resuming normal operations|command line|caught SIGWINCH' | head -15)"
    if [ -n "$TAILN" ]; then
      bad "PHP/Apache errors during that request:"
      printf '%s\n' "$TAILN" | sed 's/^/    /'
    else
      ok "no errors logged during that request"
    fi
  fi

  if grep -qi 'installer\|CiviCRM Installer' /tmp/_page.html 2>/dev/null; then
    bad "the response is the installer page"
  else
    ok "the response is not the installer page"
  fi
  rm -f /tmp/_page.html
fi

sec "8. is the database it points at actually there?"
# Read through the same parser rather than a second, independently-broken regex.
g() { printf '%s' "$VALUES" | php -r '
  $d = json_decode(stream_get_contents(STDIN), true) ?: [];
  $v = $d[$argv[1]] ?? "";
  echo is_string($v) ? $v : "";
' "$1"; }
DB_HOST="$(g db_hostname)"; DB_USER="$(g db_username)"
DB_NAME="$(g database)"; DB_PASS="$(g db_password)"; DB_PORT="$(g db_port)"
[ -n "$DB_PORT" ] || DB_PORT=3306

info "db: ${DB_USER}@${DB_HOST}/${DB_NAME}"
[ -n "$DB_HOST" ] || bad "could not read db_hostname out of the settings file"

CLI="$(command -v mariadb || command -v mysql || true)"
if [ -z "$CLI" ]; then
  info "no mysql client; skipping"
elif [ -z "$DB_HOST" ] || [ -z "$DB_USER" ]; then
  bad "not enough connection detail to test the database"
else
  OUT="$("$CLI" --connect-timeout=5 --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" \
        -u "$DB_USER" "-p${DB_PASS}" -D "${DB_NAME}" -e 'SELECT 1' 2>&1)"
  if [ $? -eq 0 ]; then
    ok "connected to the database as ${DB_USER}"
    N="$("$CLI" --connect-timeout=5 --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" \
          -u "$DB_USER" "-p${DB_PASS}" -D "$DB_NAME" \
          -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name LIKE 'civicrm\_%'" 2>/dev/null | tail -1)"
    info "civicrm_* tables: ${N:-?}"
    case "$N" in
      0|'') bad "the database has NO civicrm_* tables - the install never took,
    or this settings file points at a different database than the one that did.
    Delete the settings file and run 'make install'." ;;
      *) ok "the database has civicrm tables, so it is the right one" ;;
    esac
  else
    bad "cannot connect: $(printf '%s' "$OUT" | head -1)"
  fi
fi

sec "verdict"
info "30-install-civicrm.sh only tests for the file's EXISTENCE."
info "CiviCRM tests whether it can LOAD it. Any of the [BAD] lines above is a"
info "reason those two disagree. The fix is named next to each one."