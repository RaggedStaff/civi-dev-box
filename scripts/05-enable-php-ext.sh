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
#   2. intl.so present in PHP's own extension_dir? Enable it - first via a
#      conf.d drop-in, then by appending to php.ini, because some builds list a
#      scan dir they do not actually honour.
#   3. Not on disk but the image is official-php-derived (it has
#      docker-php-ext-install)? Compile it. Works, but is EPHEMERAL - see the
#      warning printed when that happens.
#   4. Otherwise fail loudly, and include PHP's OWN diagnostic in the message.
#      A silent "could not enable it" costs a round-trip; the startup warning
#      ("Unable to load dynamic library ... undefined symbol") says exactly why
#      in one.
#
# Everything is discovered at runtime. Do not hardcode /usr/lib64/php/modules or
# /usr/local/etc/php - those are two of several layouts and guessing wrong
# produces a php.ini edit that silently does nothing.
#
# Env: CIVICRM_EXT_TO_ENABLE  which extension to enable (default: intl)
#      CIVICRM_EXT_MODULE_PATH explicit path to the .so, if auto-discovery fails
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

# Capture stderr as well as stdout: when an extension fails to load, PHP prints
# a startup warning to stderr and exits 0, so discarding stderr hides the only
# useful clue there is.
php_modules() { php -m 2>&1 || true; }
have_ext()    { php_modules | tr 'A-Z' 'a-z' | grep -qx "$1"; }

if have_ext "$EXT"; then
  log "${EXT} is already loaded - nothing to do"
  exit 0
fi

command -v php >/dev/null 2>&1 || die "php not found on PATH"

# --- Discover where PHP actually looks ---------------------------------------
EXT_DIR="$(php -r 'echo (string) ini_get("extension_dir");' 2>/dev/null || true)"
PHP_API="$(php -r 'echo (string) PHP_VERSION;' 2>/dev/null || true)"
LOADED_INI="$(php --ini 2>/dev/null | awk -F': *' '/^Loaded Configuration File/{print $2; exit}')"
SCAN_DIR="$(php --ini 2>/dev/null | awk -F': *' '/^Scan for additional .ini files in/{print $2; exit}')"

log "php            : ${PHP_API:-<unknown>}"
log "extension_dir  : ${EXT_DIR:-<unset>}"
log "php.ini        : ${LOADED_INI:-<none>}"
log "scan dir       : ${SCAN_DIR:-<none>}"

SO="${CIVICRM_EXT_MODULE_PATH:-}"
if [ -z "$SO" ]; then
  for candidate in \
    "${EXT_DIR}/${EXT}.so" \
    "${EXT_DIR}/../modules/${EXT}.so" \
    /usr/lib64/php/modules/"${EXT}.so" \
    /usr/lib/php/modules/"${EXT}.so"
  do
    [ -n "$candidate" ] && [ -f "$candidate" ] && { SO="$candidate"; break; }
  done
fi

# --- Write the directive, and remove it again if PHP refuses -----------------
# Absolute path in the directive, so extension_dir resolution stops being a
# variable we have to get right.
write_directive() { # $1 = target ini, $2 = 1 for a conf.d drop-in
  local target="$1" dropin="$2"
  if [ "$dropin" = "1" ]; then
    mkdir -p "$(dirname "$target")" 2>/dev/null || return 1
    { echo "$MARKER"; echo "extension=${SO}"; } > "$target" || return 1
  else
    sed -i "\|^${MARKER}\$|d;\|^extension=${SO}\$|d" "$target" 2>/dev/null || true
    { echo ""; echo "$MARKER"; echo "extension=${SO}"; } >> "$target" || return 1
  fi
  return 0
}

remove_directive() { # $1 = target ini, $2 = 1 for a conf.d drop-in
  local target="$1" dropin="$2"
  [ -f "$target" ] || return 0
  if [ "$dropin" = "1" ]; then
    rm -f "$target"
  else
    sed -i "\|^${MARKER}\$|d;\|^extension=${SO}\$|d" "$target" 2>/dev/null || true
  fi
}

DIAG=""
ATTEMPTED=""

# Try each candidate location in turn. `have_ext` re-reads php.ini because the
# CLI re-parses it on every invocation, so this is a real check and not a guess.
try_location() { # $1 = label, $2 = target ini, $3 = 1 for a conf.d drop-in
  local label="$1" target="$2" dropin="$3"
  ATTEMPTED="${ATTEMPTED}\n    - ${label}: ${target}"

  write_directive "$target" "$dropin" \
    || { warn "cannot write ${target} - skipping"; return 1; }
  log "tried ${label}: extension=${SO} in ${target}"

  if have_ext "$EXT"; then
    log "${EXT} is now loaded (via ${label})"
    ENABLED_VIA="$target"
    return 0
  fi

  DIAG="$(php_modules | grep -iE 'unable to load|warning|deprecated: |error' || true)"
  warn "${label} did not take effect; reverting ${target}"
  remove_directive "$target" "$dropin"
  return 1
}

if [ -n "$SO" ]; then
  log "found ${SO}"
  [ -n "$EXT_DIR" ] && log "  (extension_dir is ${EXT_DIR})"

  # conf.d first: it is separate from the platform-managed php.ini, so the
  # platform cannot clobber it and we do not edit a file we do not own.
  if [ -n "$SCAN_DIR" ] && [ "$SCAN_DIR" != "(none)" ]; then
    try_location "conf.d drop-in" "${SCAN_DIR}/civi-${EXT}.ini" 1 || true
  fi
  if [ -z "${ENABLED_VIA:-}" ] && [ -n "$LOADED_INI" ] && [ "$LOADED_INI" != "(none)" ]; then
    try_location "php.ini" "$LOADED_INI" 0 || true
  fi

  if [ -z "${ENABLED_VIA:-}" ]; then
    {
      echo "PHP would not load ${SO}, though the file exists."
      echo
      echo "PHP's own diagnostic:"
      if [ -n "$DIAG" ]; then
        printf '  %s\n' "$DIAG"
      else
        echo "  (none - PHP printed no warning)"
      fi
      echo
      echo "Context:"
      echo "  php            : ${PHP_API}"
      echo "  extension_dir  : ${EXT_DIR}"
      echo "  php api version: $(php -r 'echo (int) PHP_MAJOR_VERSION * 1000000 + (int) PHP_MINOR_VERSION * 1000 + (int) PHP_RELEASE_VERSION;' 2>/dev/null || echo unknown)"
      if command -v ldd >/dev/null 2>&1; then
        echo "  missing libs   : $(ldd "$SO" 2>/dev/null | grep 'not found' | awk '{print $1}' | paste -sd, - || true)"
      fi
      echo
      echo "Locations tried:"
      printf "%b\n" "$ATTEMPTED"
      echo
      echo "Most likely cause: the .so was built for a different PHP API version than"
      echo "the running one, or a shared library it needs is absent. Check whether"
      echo "the platform's modules folder carries per-version subdirectories, and"
      echo "point at the right one with CIVICRM_EXT_MODULE_PATH."
    } | sed 's/^/  /' >&2
    die "could not enable ${EXT}; PHP's diagnostic is above."
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
  command -v docker-php-ext-enable >/dev/null 2>&1 && docker-php-ext-enable "$EXT" || true
  have_ext "$EXT" || die "${EXT} still not loaded after docker-php-ext-install."
else
  die "${EXT}.so is not on disk and this image has no docker-php-ext-install,
    so it cannot be enabled or built automatically.
    Either use a PHP image that ships ${EXT}, or upload a compiled ${EXT}.so to
    PHP's extension_dir and enable it in php.ini
    (dashboard > node > Config > etc > php.ini)."
fi

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