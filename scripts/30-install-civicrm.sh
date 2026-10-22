#!/usr/bin/env bash
# 30-install-civicrm.sh - run ON THE PHP CONTAINER.
#
# Runs the non-interactive CiviCRM installer (`cv core:install`), which is the
# documented CLI path for Standalone:
#
#   cv core:install -v \
#     --cms-base-url=http://localhost:8000 \
#     --db=mysql://USER:PASS@HOST:PORT/DATABASE \
#     -m extras.adminUser=USERNAME \
#     -m extras.adminPass=SECRET \
#     -m extras.adminEmail=ME@EXAMPLE.COM
#
# Idempotent: exits immediately if the site is already installed, so this is
# safe to wire into onAfterRestartNode.
set -euo pipefail
# shellcheck source=lib.sh
_CIVI_SELF="${BASH_SOURCE[0]:-$0}"
. "$(dirname "$_CIVI_SELF")/lib.sh" || {
  echo "civi: cannot source lib.sh (looked next to '${_CIVI_SELF}')" >&2
  echo "civi: run this script as a FILE - piping it into 'bash -s' leaves BASH_SOURCE unset." >&2
  echo "civi: JPS hooks must use: curl -fsS <url> -o \$d/NAME.sh && bash \$d/NAME.sh" >&2
  exit 1
}

log "=== install civicrm ==="

APP_ROOT="$(detect_app_root)"
CIVICRM_APP_DIR="$APP_ROOT"
cd "$APP_ROOT"

# --- Already installed? -----------------------------------------------------
# "Installed" is not enough. CiviCRM shows its web installer whenever the WEB
# user cannot see the settings file, so an already-installed box can still be
# broken in the browser - and exiting on the strength of root's view is what
# made that state look permanent. Repair, then confirm.
if civicrm_installed; then
  log "civicrm.settings.php defines a database - site already installed"
  if settings_visible_to_web; then
    log "the webserver can load it - nothing to do"
    exit 0
  fi
  warn "but the webserver cannot see it, so CiviCRM will show its web installer"
  warn "  repairing data-dir ownership"
  ensure_data_dirs >/dev/null 2>&1 || warn "ensure_data_dirs reported a problem"
  if settings_visible_to_web; then
    log "repaired: the webserver can now see it - nothing else to do"
    exit 0
  fi
  die "the site IS installed, but the webserver cannot see
    $(detect_app_root)/private/civicrm.settings.php
    so CiviCRM shows its web installer instead of the site. Re-installing
    cannot help: the database and the settings file are already correct.
    Compare root's view with the webserver's:
      ls -ld $(detect_app_root)/private $(data_private)
      su -s /bin/sh www-data -c 'ls -l $(detect_app_root)/private/civicrm.settings.php'"
fi

# --- Settings --------------------------------------------------------------
# Default these the same way the MariaDB image's env block does. It creates the user with
# CIVICRM_DB_USER defaulted to 'civicrm', so defaulting here too keeps the two
# scripts in agreement; without it, running this script without the node env set
# dies on `set -u` with "CIVICRM_DB_USER: unbound variable".
: "${CIVICRM_DB_NAME:=civicrm}"
: "${CIVICRM_DB_USER:=civicrm}"

DB_HOST="$(resolve_db_host)"
[ -n "$DB_HOST" ] || die "cannot resolve database host (set CIVICRM_DB_HOST)"
[ -n "$CIVICRM_DB_PASS" ] || die "CIVICRM_DB_PASS must be provided"
[ -n "$CIVICRM_ADMIN_PASS" ] || die "CIVICRM_ADMIN_PASS must be provided"

# The site URL is baked into the install. On Jelastic this is the environment
# URL, passed in by the manifest as CIVICRM_SITE_URL.
SITE_URL="${CIVICRM_SITE_URL:-${env.url}}"
: "${SITE_URL:=http://localhost}"
SITE_URL="${SITE_URL%/}"
log "site url:  ${SITE_URL}"
log "database:  ${CIVICRM_DB_USER}@${DB_HOST}:${CIVICRM_DB_PORT}/${CIVICRM_DB_NAME}"

wait_for_db

SITE_KEY="$(generate_site_key)"
[ -n "$SITE_KEY" ] || die "could not generate a site key"

CV="$(ensure_cv)"
log "cv: $("$CV" --version 2>&1 | head -1 || echo unknown)"

# --- Build the command ------------------------------------------------------
# Extra settings are passed as -m key=value pairs. Demo data is the flag-gated
# part requested: it is only added when CIVICRM_DEMO_DATA is truthy.
EXTRA_ARGS=(
  -m "extras.adminUser=${CIVICRM_ADMIN_USER}"
  -m "extras.adminPass=${CIVICRM_ADMIN_PASS}"
  -m "extras.adminEmail=${CIVICRM_ADMIN_EMAIL}"
  -m "siteKey=${SITE_KEY}"
)

# Demo data is the flag-gated part requested: only added when the setting is
# truthy. Guarded, since it is optional and a bare reference aborts under `set -u`.
# Lower-cased, so TRUE/True/Yes are not silently read as "disabled".
case "${CIVICRM_DEMO_DATA,,}" in
  1|true|yes|on)
    log "demo data: ENABLED (install will take considerably longer)"
    EXTRA_ARGS+=( -m "extras.demoData=yes" )
    ;;
  *)
    log "demo data: disabled"
    EXTRA_ARGS+=( -m "extras.demoData=no" )
    ;;
esac

DB_URL="mysql://${CIVICRM_DB_USER}:${CIVICRM_DB_PASS}@${DB_HOST}:${CIVICRM_DB_PORT}/${CIVICRM_DB_NAME}"

# --- Reconcile with any existing settings file --------------------------------
# cv core:install PROMPTS when one is already there:
#
#     Found existing civicrm.settings.php in /var/www/html/private
#     The civicrm.settings.php already exists. What would you like to do?
#       [a] Abort. (Default.) ...
#      >
#     [Exception]  Aborted
#
# With no TTY nothing answers, the default is Abort, and the install dies. It is
# a contradiction between two decisions: this script judged the site NOT
# installed (otherwise it exited at the guard above), while a settings file from
# an earlier or partial attempt was still sitting on disk. The script lost the
# argument by hanging on a question nobody could answer.
#
# So settle it here, where the reason can be logged, rather than letting cv
# settle it silently. -f is cv's own answer for [o], "overwrite": appropriate
# because the only way we reach this point is having already judged this file
# not to be a usable configuration. Nothing recognised as good is discarded, and
# the previous copy is kept either way - the same reasoning as .htaccess.lost.
SETTINGS_FILE="${APP_ROOT}/private/civicrm.settings.php"
if [ -f "$SETTINGS_FILE" ]; then
  if cp -p "$SETTINGS_FILE" "${SETTINGS_FILE}.preinstall.bak" 2>/dev/null; then
    log "kept the previous settings file as ${SETTINGS_FILE}.preinstall.bak"
  else
    warn "could not back up ${SETTINGS_FILE}"
  fi
  warn "an existing civicrm.settings.php will be OVERWRITTEN (-f)."
  warn "  Reached only because the install guard judged it not usable, so this"
  warn "  keeps nothing that was recognised as good."
  warn "  To see what it contains: bash scripts/read-settings.php ${SETTINGS_FILE}"
  EXTRA_ARGS+=( -f )
fi

log "running: cv core:install --cms-base-url=${SITE_URL} --db=mysql://*** ${EXTRA_ARGS[*]}"

set +e
"$CV" core:install \
  -v \
  --cms-base-url="$SITE_URL" \
  --db="$DB_URL" \
  "${EXTRA_ARGS[@]}" \
  2>&1 | tee "${TMPDIR:-/tmp}/civicrm-install.log"
STATUS="${PIPESTATUS[0]}"
set -e

if [ "$STATUS" -ne 0 ]; then
  warn "cv core:install failed (exit ${STATUS}). Tail of the log:"
  tail -40 "${TMPDIR:-/tmp}/civicrm-install.log" >&2 || true
  die "installation did not complete"
fi

# --- Verify ----------------------------------------------------------------
# `cv core:install` exiting 0 is the authoritative signal that the install
# worked. It created the tables and wrote the settings file.
#
# civicrm_installed() is a heuristic, and it must never be able to fail an
# install that succeeded. An earlier version gated on it with `die`, so a
# heuristic that disagreed with the installer turned two successful installs
# into failed imports - and the disagreement was never evidence that anything
# was wrong. It now only warns, loudly and with the file to look at.
SETTINGS_PATH="$(detect_app_root)/private/civicrm.settings.php"

if [ ! -f "$SETTINGS_PATH" ]; then
  # This one is a real failure: the installer said it wrote the file.
  die "cv core:install exited 0 but ${SETTINGS_PATH} does not exist.
    Its JSON output reports which path it wrote - compare that with
    ${SETTINGS_PATH}. If they differ, the installer used a different
    document root."
fi

if ! civicrm_installed; then
  warn "cv core:install succeeded, but the guard in lib.sh does not recognise"
  warn "${SETTINGS_PATH} as an installed configuration."
  warn "Continuing: the installer's exit status is authoritative and this check"
  warn "is only a heuristic. The early-exit at the top of this script uses it to"
  warn "decide whether to re-install, so it may re-run harmlessly next time."
  warn "To see what the file contains:  head -40 ${SETTINGS_PATH}"
fi

# Rewrite ownership so the webserver user can write the three trees.
#
# The webserver process may be a parent (apache2/httpd/php-fpm) whose workers run
# as an unprivileged user such as www-data, so the parent name is not always the
# name to chown to. Prefer an explicit CIVICRM_WEB_USER, then probe the pool
# config, then fall back to the master process.
detect_web_user() {
  # Guarded, because CIVICRM_WEB_USER is an optional override that the JPS does
  # not set. A bare reference here aborted the install under `set -u` - and it
  # did so immediately AFTER `cv core:install` had already created the database
  # tables and written the settings file, which made a successful install look
  # like a total failure.
  if [ -n "${CIVICRM_WEB_USER:-}" ]; then printf '%s' "$CIVICRM_WEB_USER"; return 0; fi

  # Ask each candidate how it will drop privileges.
  local c
  for c in apache2 apache httpd nginx php-fpm; do
    command -v "$c" >/dev/null 2>&1 || continue
    local u
    u="$("$c" -t -D DUMP_RUN_CFG 2>/dev/null | awk -F'"' '/User|user/ {print $2; exit}')"
    [ -n "$u" ] && [ "$u" != "root" ] && { printf '%s' "$u"; return 0; }
  done

  # Fallback: the user owning the master webserver process.
  ps -eo user,comm 2>/dev/null | awk '$2 ~ /apache2|httpd|nginx|php-fpm/ {print $1; exit}'
}

WEB_USER="$(detect_web_user || true)"
if [ -n "$WEB_USER" ]; then
  log "webserver user: ${WEB_USER}"
  if [ "$(id -u)" = "0" ]; then
    chown -R "${WEB_USER}:${WEB_USER}" "$(data_private)" "$(data_public)" "$(data_ext)" 2>/dev/null \
      || warn "could not chown the writable trees to ${WEB_USER}"
  fi
else
  warn "could not determine the webserver user; the site may fail to write uploads.
    Set CIVICRM_WEB_USER explicitly (or install as the owning user) and re-run."
fi

# CiviCRM's own documented permissions recipe: group-write + setgid so files
# created later inherit the directory group.
chmod -R u+rwX,g+rwX "$(data_private)" "$(data_public)" "$(data_ext)" 2>/dev/null || true
chmod 2770 "$(data_private)" "$(data_public)" "$(data_ext)" 2>/dev/null || true

# --- Can the WEBSERVER see the settings file? --------------------------------
# Every check up to here ran as root, and root can see every file. CiviCRM
# decides between the site and its web installer with
# `defined('CIVICRM_SETTINGS_PATH')`, which is set only when bootSettings() finds
# the file with file_exists() - as the WEB user. So a settings file root can
# read and www-data cannot produces the worst possible result: this script
# reports success, the database is installed, and the browser still shows the
# installer. That is a permissions fault wearing a database fault's clothes.
if settings_visible_to_web; then
  log "the webserver can load ${SETTINGS_PATH}"
else
  warn "the webserver CANNOT see ${SETTINGS_PATH}"
  warn "  CiviCRM shows its web installer whenever file_exists() is false for the"
  warn "  web user, so the site will keep showing the installer however often the"
  warn "  install runs. Repairing data-dir ownership and asking again."
  ensure_data_dirs >/dev/null 2>&1 || warn "ensure_data_dirs reported a problem"
  if settings_visible_to_web; then
    log "repaired: the webserver can now see the settings file"
  else
    stat -c '    %n  %U:%G %a' "$SETTINGS_PATH" >&2 2>/dev/null || true
    die "the webserver cannot see ${SETTINGS_PATH} even after repairing ownership.
    This is the exact condition that makes CiviCRM display its installer: the
    site is installed, but the web process cannot find the file.
    Compare root's view with the webserver's:
      ls -ld $(detect_app_root)/private $(data_private)
      su -s /bin/sh www-data -c 'ls -l ${SETTINGS_PATH}'
    If private/ is a symlink, its target must be traversable by www-data. If the
    parent mode is 2770 and the owner is not www-data, the web user has no
    access at all."
  fi
fi

log "installed. log in at ${SITE_URL}/civicrm/login"
log "admin user: ${CIVICRM_ADMIN_USER} <${CIVICRM_ADMIN_EMAIL}>"
log "=== install complete ==="
