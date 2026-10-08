#!/usr/bin/env bash
# 05-enable-php-ext.sh - run ON THE PHP CONTAINER, before 00-preflight.sh.
#
# Why this exists: the platform's PHP image ships WITHOUT intl loaded, and
# 00-preflight.sh correctly refuses to go further, because CiviCRM's own
# requirements say:
#
#     "PHP INTL - required for outputting localized formatted number strings
#      from CiviCRM 5.28 onwards"
#
# So this is a real gap, not a false alarm. The platform's PHP Extensions
# documentation lists intl.so among the dynamic extensions available to Apache,
# NGINX and LiteSpeed PHP, which means in the normal case the binary is already
# on disk and only needs enabling.
#
# Strategy, in order of preference:
#
#   1. Already loaded? Then there is nothing to do.
#   2. intl.so present in PHP's own extension_dir? Enable it in php.ini.
#      This is the expected path and matches the vendor's documented
#      procedure (dashboard > Config > etc/php.ini > uncomment
#      extension=intl.so).
#   3. Not on disk but the image is official-php-derived (it has
#      docker-php-ext-install)? Compile it. Works, but is EPHEMERAL - see the
#      warning printed when that happens.
#   4. Otherwise fail loudly with the vendor's manual route.
#
# Everything is discovered at runtime. Do not hardcode /usr/lib64/php/modules or
# /usr/local/etc/php - those are two of several layouts and guessing wrong
# produces a php.ini edit that silently does nothing.
#
# Env: (none required)
set -euo pipefail
# shellcheck source=lib.sh
_CIVI_SELF="${BASH_SOURCE[0]:-$0}"
. "$(dirname "$_CIVI_SELF")/lib.sh" || {
  echo "civi: cannot source lib.sh (looked next to '${_CIVI_SELF}')" >&2
  echo "civi: run this script as a FILE - piping it into 'bash -s' leaves BASH_SOURCE unset." >&2
  echo "civi: JPS hooks must use: curl -fsS <url> -o \$d/NAME.sh && bash \$d/NAME.sh" >&2
  exit 1
}

EXT="${CIVICRM_EXT_TO_ENABLE:-intl}"
MARKER="# managed by civi-dev-box ($EXT)"

log "=== enable php extension: ${EXT} ==="

have_ext() { php -m 2>/dev/null | tr 'A-Z' 'a-z' | grep -qx "$1"; }

if have_ext "$EXT"; then
  log "${EXT} is already loaded - nothing to do"
  exit 0
fi

command -v php >/dev/null 2>&1 || die "php not found on PATH"

# --- Discover where PHP actually looks ---------------------------------------
EXT_DIR="$(php -r 'echo (string) ini_get("extension_dir");' 2>/dev/null || true)"
LOADED_INI="$(php --ini 2>/dev/null | awk -F': *' '/^Loaded Configuration File/{print $2; exit}')"
SCAN_DIR="$(php --ini 2>/dev/null | awk -F': *' '/^Scan for additional .ini files in/{print $2; exit}')"

log "extension_dir : ${EXT_DIR:-<unset>}"
log "php.ini       : ${LOADED_INI:-<none>}"
log "scan dir      : ${SCAN_DIR:-<none>}"

SO=""
for candidate in \
  "${EXT_DIR}/${EXT}.so" \
  "${EXT_DIR}/../modules/${EXT}.so" \
  /usr/lib64/php/modules/"${EXT}.so" \
  /usr/lib/php/modules/"${EXT}.so"
do
  [ -n "$candidate" ] && [ -f "$candidate" ] && { SO="$candidate"; break; }
done

# --- Where to put the directive ------------------------------------------------
# Prefer a conf.d drop-in: it is separate from the platform-managed php.ini, so
# the platform cannot clobber it and we do not have to edit a file it owns.
TARGET_INI=""
if [ -n "$SCAN_DIR" ] && [ "$SCAN_DIR" != "(none)" ] && mkdir -p "$SCAN_DIR" 2>/dev/null \
   && [ -w "$SCAN_DIR" ]; then
  TARGET_INI="${SCAN_DIR}/civi-${EXT}.ini"
  USING_SCAN_DIR=1
elif [ -n "$LOADED_INI" ] && [ "$LOADED_INI" != "(none)" ] && [ -w "$LOADED_INI" ]; then
  TARGET_INI="$LOADED_INI"
  USING_SCAN_DIR=0
else
  USING_SCAN_DIR=0
fi

enable_via_ini() {
  [ -n "$TARGET_INI" ] || return 1

  if [ "${USING_SCAN_DIR}" = "1" ]; then
    {
      echo "$MARKER"
      echo "extension=${EXT}.so"
    } > "$TARGET_INI"
  else
    # Idempotent: strip any previous block, then append a fresh one.
    sed -i "\|^${MARKER}\$|d;\|^extension=${EXT}\.so\$|d" "$TARGET_INI" 2>/dev/null || true
    {
      echo ""
      echo "$MARKER"
      echo "extension=${EXT}.so"
    } >> "$TARGET_INI"
  fi
  log "wrote extension=${EXT}.so to ${TARGET_INI}"
  return 0
}

if [ -n "$SO" ]; then
  log "found ${SO}"
  if ! enable_via_ini; then
    die "found ${SO} but no writable php.ini or conf.d directory to enable it in.
    Enable it by hand: dashboard > node > Config > etc > php.ini, uncomment
    'extension=${EXT}.so', save, restart the node."
  fi
elif command -v docker-php-ext-install >/dev/null 2>&1; then
  # Official-php-derived image. Compiling works but lives in the container
  # filesystem, so a node replacement loses it. onAfterRestartNode re-runs this
  # script, which is what keeps a redeployed box working.
  warn "${EXT}.so is not on disk; compiling it from source."
  warn "This is EPHEMERAL - it lives in the container filesystem, not the volume."
  warn "It is re-installed on every node restart by the onAfterRestartNode hook."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq || die "apt-get update failed (no network?)"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      libicu-dev g++ make autoconf pkg-config \
      || die "could not install libicu-dev and the build toolchain"
    docker-php-ext-install -j"$(nproc 2>/dev/null || echo 1)" "$EXT" \
      || die "docker-php-ext-install ${EXT} failed"
  else
    die "no apt-get on this image and ${EXT}.so is absent, so it cannot be built here.
    Build ${EXT}.so elsewhere and upload it to PHP's extension_dir, then enable it
    (dashboard > node > Config > etc > php.ini), or use a custom image."
  fi
  # docker-php-ext-install drops the .so and docker-php-ext-enable writes the ini.
  command -v docker-php-ext-enable >/dev/null 2>&1 && docker-php-ext-enable "$EXT" || true
else
  die "${EXT}.so is not on disk and this image has no docker-php-ext-install,
    so it cannot be enabled or built automatically.
    Either use a PHP image that ships ${EXT}, or upload a compiled ${EXT}.so to
    PHP's extension_dir and enable it in php.ini
    (dashboard > node > Config > etc > php.ini)."
fi

# --- Verify, and roll back a directive that PHP refuses ----------------------
if ! have_ext "$EXT"; then
  if [ -n "$TARGET_INI" ] && [ -w "$TARGET_INI" ]; then
    warn "PHP still does not list ${EXT} after enabling it; reverting the ini change."
    if [ "${USING_SCAN_DIR}" = "1" ]; then
      # The drop-in is ours, so remove it rather than leave an empty file that
      # PHP would still read on every request.
      rm -f "$TARGET_INI"
      log "removed ${TARGET_INI}"
    else
      sed -i "\|^${MARKER}\$|d;\|^extension=${EXT}\.so\$|d" "$TARGET_INI" 2>/dev/null || true
    fi
  fi
  die "could not enable ${EXT}. PHP may have been built without it, or the .so
    will not load (missing shared library). Check the PHP error log, or set
    CIVICRM_EXT_TO_ENABLE to something this build supports."
fi

log "${EXT} is now loaded"

# The CLI reads php.ini fresh on every invocation, so the check above is real.
# The web SAPI caches it at startup, so a running Apache/PHP still needs a nudge.
if pgrep -x apache2 >/dev/null 2>&1 || pgrep -x httpd >/dev/null 2>&1 \
   || pgrep -x php-fpm >/dev/null 2>&1; then
  log "a web SAPI is running - sending it a graceful restart to pick up php.ini"
  if command -v apachectl >/dev/null 2>&1; then
    apachectl -k graceful 2>/dev/null || service apache2 reload >/dev/null 2>&1 || true
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl reload apache2 >/dev/null 2>&1 || systemctl reload httpd >/dev/null 2>&1 || true
  fi
fi