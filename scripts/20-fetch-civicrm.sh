#!/usr/bin/env bash
# 20-fetch-civicrm.sh - run ON THE PHP CONTAINER.
#
# Installs CiviCRM Standalone into the application document root and wires the
# three writable trees (private/, public/, ext/) to the persistent volumes.
#
# Idempotent: safe to run on every container start. If the release code is
# already present it is left alone; only the volume symlinks are repaired.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log "=== fetch civicrm ${CIVICRM_VERSION} ==="

TARBALL="civicrm-${CIVICRM_VERSION}-standalone.tar.gz"
URL="${DOWNLOAD_BASE}/${TARBALL}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Resolve the app root ---------------------------------------------------
# The release must be extracted *into* a directory that will become the
# webserver document root, because CiviCRM Standalone explicitly does not
# support installation into a URL subdirectory.
APP_ROOT="${CIVICRM_APP_DIR:-${HOME}/apps/civicrm}"
mkdir -p "$APP_ROOT"
CIVICRM_APP_DIR="$APP_ROOT"

if [ -f "${APP_ROOT}/civicrm.standalone.php" ]; then
  log "release code already present in ${APP_ROOT} - skipping download"
else
  log "downloading ${URL}"
  curl -fsSL --retry 3 --retry-delay 2 "$URL" -o "${TMP}/${TARBALL}" \
    || die "failed to download ${URL}"

  if [ -n "${CIVICRM_SHA256:-}" ]; then
    log "verifying sha256"
    echo "${CIVICRM_SHA256}  ${TMP}/${TARBALL}" | sha256sum -c - \
      || die "checksum mismatch for ${TARBALL}"
  fi

  log "extracting"
  tar -xzf "${TMP}/${TARBALL}" -C "$TMP"

  # The tarball may or may not contain a single top-level directory.
  EXTRACTED="$TMP"
  if [ ! -f "${TMP}/civicrm.standalone.php" ]; then
    INNER="$(find "$TMP" -mindepth 2 -maxdepth 2 -name civicrm.standalone.php -print -quit)"
    [ -n "$INNER" ] || die "unexpected tarball layout: civicrm.standalone.php not found"
    EXTRACTED="$(dirname "$INNER")"
  fi

  cp -a "${EXTRACTED}/." "$APP_ROOT/"
  log "release code installed into ${APP_ROOT}"
fi

# --- Bind writable trees to persistent volumes ------------------------------
link_data_dirs

# --- Per-directory PHP ini --------------------------------------------------
# Written twice, because the mechanism depends on the SAPI and the wrong one is
# silently ignored:
#
#   .user.ini    honoured by CGI/FastCGI SAPIs (so PHP-FPM)
#   .htaccess    php_value directives, honoured by mod_php (Apache's classic)
#
# On Apache+mod_php, .user.ini is read by nobody. On PHP-FPM, php_value inside
# .htaccess is not permitted. Neither approach touches the platform's global
# php.ini, so both survive redeploy and are not clobbered by the provider.
INI_BODY=$(cat <<'INI'
; CiviCRM recommended minimums (installation requirements page).
memory_limit = 512M
max_execution_time = 240
max_input_time = 120
post_max_size = 50M
upload_max_filesize = 50M
; Keep opcache honest while the extension is being iterated on: stale bytecode
; hides edits, which is the classic "my change did nothing" trap.
opcache.validate_timestamps = 1
opcache.revalidate_freq = 0
INI
)

cat > "${APP_ROOT}/.user.ini" <<INI
; Managed by civi-dev-box - used by PHP-FPM/CGI.
${INI_BODY}
INI
log "wrote ${APP_ROOT}/.user.ini"

# --- .htaccess -------------------------------------------------------------
# Two jobs:
#   1. mod_php equivalent of the ini settings above (php_value)
#   2. deny direct web access to private/ - which is how CiviCRM itself expects
#      to be protected. Apache honours this; NGINX would need a hand-written vhost.
# mod_php honours PHP_INI_PERDIR settings from .htaccess. Only the directives
# below are legal there - php_value on a PHP_INI_SYSTEM directive such as
# opcache.revalidate_freq makes Apache return 500 on every request, and the
# AllowOverride the platform sets may not even permit the whole set.
#
# Guarded by IfModule so this file is inert on PHP-FPM, where php_value is not
# permitted and .user.ini above does the job instead.
PHP_VALUE_BLOCK=""
for kv in "memory_limit 512M" \
          "max_execution_time 240" \
          "max_input_time 120" \
          "post_max_size 50M" \
          "upload_max_filesize 50M"; do
    key="${kv%% *}"
    val="${kv#* }"
    PHP_VALUE_BLOCK="${PHP_VALUE_BLOCK}
<IfModule mod_php.c>
  php_value ${key} ${val}
</IfModule>"
done

cat > "${APP_ROOT}/.htaccess" <<HTA
# Managed by civi-dev-box
${PHP_VALUE_BLOCK}
HTA
log "wrote ${APP_ROOT}/.htaccess (mod_php ini equivalents)"

# private/ must never be web-readable - it holds civicrm.settings.php, which
# contains the DB credentials. Deny it explicitly rather than relying on the
# release's own rules, which have been observed to be absent from some builds.
# Both Apache 2.2 and 2.4 syntax, so this works either way.
cat > "${APP_ROOT}/private/.htaccess" <<'HTA'
# Managed by civi-dev-box - private/ holds DB credentials and uploads.
<IfModule mod_authz_core.c>
  Require all denied
</IfModule>
<IfModule !mod_authz_core.c>
  Order allow,deny
  Deny from all
</IfModule>
HTA
log "wrote ${APP_ROOT}/private/.htaccess (deny all)"

# core/ contains PHP internals that must not be executed directly. Apache runs
# .php under mod_php here, so deny rather than rely on routing.
cat > "${APP_ROOT}/core/.htaccess" <<'HTA'
# Managed by civi-dev-box - core/ is not a public entrypoint.
<IfModule mod_authz_core.c>
  Require all denied
</IfModule>
<IfModule !mod_authz_core.c>
  Order allow,deny
  Deny from all
</IfModule>
HTA

log "installed civicrm version marker: $(cat "${APP_ROOT}/core/civicrm/version.php" 2>/dev/null | grep -o "VERSION = '[^']*'" || echo 'unknown')"
log "=== fetch complete ==="
