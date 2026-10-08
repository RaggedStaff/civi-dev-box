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
if civicrm_installed; then
  log "civicrm.settings.php present - site already installed, nothing to do"
  exit 0
fi

# --- Settings --------------------------------------------------------------
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

if [ "${CIVICRM_DEMO_DATA}" = "1" ] || [ "${CIVICRM_DEMO_DATA}" = "true" ]; then
  log "demo data: ENABLED (install will take considerably longer)"
  EXTRA_ARGS+=( -m "extras.demoData=yes" )
else
  log "demo data: disabled"
  EXTRA_ARGS+=( -m "extras.demoData=no" )
fi

DB_URL="mysql://${CIVICRM_DB_USER}:${CIVICRM_DB_PASS}@${DB_HOST}:${CIVICRM_DB_PORT}/${CIVICRM_DB_NAME}"

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
civicrm_installed || die "installer reported success but private/civicrm.settings.php is missing"

# Rewrite ownership so the webserver user can write the three trees.
#
# The webserver process may be a parent (apache2/httpd/php-fpm) whose workers run
# as an unprivileged user such as www-data, so the parent name is not always the
# name to chown to. Prefer an explicit CIVICRM_WEB_USER, then probe the pool
# config, then fall back to the master process.
detect_web_user() {
  if [ -n "$CIVICRM_WEB_USER" ]; then printf '%s' "$CIVICRM_WEB_USER"; return 0; fi

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

log "installed. log in at ${SITE_URL}/civicrm/login"
log "admin user: ${CIVICRM_ADMIN_USER} <${CIVICRM_ADMIN_EMAIL}>"
log "=== install complete ==="
