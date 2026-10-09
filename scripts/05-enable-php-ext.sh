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
# The platform's PHP Extensions documentation lists intl.so among the dynamic
# extensions available to Apache, NGINX and LiteSpeed PHP, so the binary is
# already on disk and only needs enabling.
#
# Strategy:
#
#   1. Already loaded? Nothing to do.
#   2. Try a conf.d drop-in. Harmless where it works, and it keeps our edit away
#      from the platform-managed php.ini.
#   3. Otherwise enable it in php.ini - but PREPEND, never append.
#
# On why prepend (the hard-won part):
#
#   This platform's /etc/php.ini already contains a syntax error. PHP's ini
#   parser reports it and then STOPS parsing that file: every directive after
#   the error is silently discarded. Verified locally - with a deliberate
#   "this is (not valid ini" line, a directive before it is honoured and one
#   after it falls back to its compiled default.
#
#   So an appended `extension=intl.so` lands past the error and does nothing,
#   while reporting "PHP would not load it". The line number in PHP's own
#   message ("syntax error, unexpected '(' in /etc/php.ini on line 688") is the
#   whole diagnosis. Inserting above the first error sidesteps it.
#
#   The original file is copied to <php.ini>.civi-orig before we touch it, and
#   restored byte-for-byte on any failure - editing a file we do not own with
#   sed surgery is how you leave a node unable to start PHP at all.
#
# Env: CIVICRM_EXT_TO_ENABLE   which extension to enable (default: intl)
#      CIVICRM_EXT_MODULE_PATH explicit path to the .so, if discovery fails
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
# No parentheses in the marker: they are the exact token PHP complained about,
# and if this ever gets glued onto a line it must not produce a parse error.
MARKER="# civi-dev-box managed block"
BACKUP=""

log "=== enable php extension: ${EXT} ==="

# `php --ini` wraps its paths in double quotes on some builds:
#     Loaded Configuration File: "/etc/php.ini"
# Capturing the value after the colon keeps the quotes, and every later write
# then lands in a file literally named '"/etc/php.ini"' in the working
# directory. PHP is never told to load anything, and the failure looks exactly
# like "this build cannot load the extension".
unquote() {
  local s="${1:-}"
  case "$s" in
    \"*\") s="${s#\"}"; s="${s%\"}" ;;
    \'*\') s="${s#\'}"; s="${s%\'}" ;;
  esac
  printf '%s' "$s"
}

# Note the non-zero exit: `php -m` returns 255 when php.ini has a parse error,
# and still prints the module list. Capturing stderr as well as stdout is
# essential - the startup warning IS the diagnostic.
php_modules() { php -m 2>&1 || true; }
have_ext()    { php_modules | tr 'A-Z' 'a-z' | grep -qx "$1"; }
php_problems() { php_modules | grep -iE 'syntax error|unable to load dynamic' | head -5 || true; }

if have_ext "$EXT"; then
  log "${EXT} is already loaded - nothing to do"
  exit 0
fi

command -v php >/dev/null 2>&1 || die "php not found on PATH"

# --- Discover where PHP actually looks ---------------------------------------
EXT_DIR="$(unquote "$(php -r 'echo (string) ini_get("extension_dir");' 2>/dev/null || true)")"
PHP_API="$(php -r 'echo (string) PHP_VERSION;' 2>/dev/null || true)"
API_NUM="$(php -r 'echo (int) PHP_MAJOR_VERSION * 1000000 + (int) PHP_MINOR_VERSION * 1000 + (int) PHP_RELEASE_VERSION;' 2>/dev/null || echo unknown)"
LOADED_INI="$(unquote "$(php --ini 2>/dev/null | awk -F': *' '/^Loaded Configuration File/{print $2; exit}')")"
SCAN_DIR="$(unquote "$(php --ini 2>/dev/null | awk -F': *' '/^Scan for additional .ini files in/{print $2; exit}')")"

# Capture the state BEFORE we change anything, so a pre-existing problem is
# never reported as one we caused.
BASELINE_PROBLEMS="$(php_problems)"
if [ -n "$BASELINE_PROBLEMS" ]; then
  warn "PHP already reports a problem BEFORE any change is made - not ours:"
  printf '    %s\n' "$BASELINE_PROBLEMS"
fi

log "php            : ${PHP_API:-<unknown>} (api ${API_NUM})"
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

# --- Write / restore ---------------------------------------------------------
# $2 is the mode: 1 = drop-in file we own, 2 = prepend into an existing ini.
# Both preserve the original inode and permissions of an existing file, which
# matters because php.ini is platform-managed.
write_directive() {
  local target="$1" mode="$2" tmp
  case "$mode" in
    1)
      { echo "$MARKER"; echo "extension=${SO}"; } > "$target" || return 1
      ;;
    2)
      tmp="$(mktemp "${target}.civi.XXXXXX" 2>/dev/null)" || return 1
      { echo "$MARKER"; echo "extension=${SO}"; echo ""; cat "$target"; } > "$tmp" || {
        rm -f "$tmp"; return 1; }
      # cat > rather than mv: keeps the inode, owner and mode of the file the
      # platform gave us.
      cat "$tmp" > "$target" || { rm -f "$tmp"; return 1; }
      rm -f "$tmp"
      ;;
  esac
  return 0
}

remove_directive() {
  local target="$1" mode="$2"
  case "$mode" in
    1) [ -f "$target" ] && rm -f "$target" || true ;;
    2)
      # Byte-for-byte restore from the pristine copy.
      if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
        cat "$BACKUP" > "$target" || true
        log "restored ${target} from ${BACKUP}"
      fi
      ;;
  esac
}

DIAG=""
ATTEMPTED=""
ENABLED_VIA=""

try_location() { # $1 = label, $2 = target, $3 = mode
  local label="$1" target="$2" mode="$3" parent

  # Refuse anything that is not a real, existing, absolute path. Without this a
  # malformed path still "succeeds", because the shell creates whatever it is
  # asked for, and the run then fails with a misleading message.
  case "$target" in
    /*) : ;;
    *)  warn "skipping ${label}: '${target}' is not an absolute path"; return 1 ;;
  esac
  parent="$(dirname "$target")"
  if [ ! -d "$parent" ]; then
    if [ "$mode" = "1" ] && mkdir -p "$parent" 2>/dev/null && [ -d "$parent" ]; then
      log "created ${parent} for the ${label}"
    else
      warn "skipping ${label}: '${parent}' does not exist"
      return 1
    fi
  fi

  ATTEMPTED="${ATTEMPTED}\n    - ${label}: ${target}"
  write_directive "$target" "$mode" \
    || { warn "cannot write ${target} - skipping"; return 1; }
  log "tried ${label}: extension=${SO} in ${target}"

  if have_ext "$EXT"; then
    log "${EXT} is now loaded (via ${label})"
    ENABLED_VIA="$label"
    return 0
  fi

  DIAG="$(php_problems)"
  warn "${label} did not take effect; reverting ${target}"
  remove_directive "$target" "$mode"
  return 1
}

if [ -n "$SO" ]; then
  log "found ${SO}"

  # 1. A drop-in we own. Preferred where it is honoured.
  if [ -n "$SCAN_DIR" ] && [ "$SCAN_DIR" != "(none)" ]; then
    try_location "conf.d drop-in" "${SCAN_DIR}/civi-${EXT}.ini" 1 || true
  fi

  # 2. php.ini, prepended above any parse error.
  if [ -z "$ENABLED_VIA" ] && [ -n "$LOADED_INI" ] && [ "$LOADED_INI" != "(none)" ] \
     && [ -f "$LOADED_INI" ]; then
    BACKUP="${LOADED_INI}.civi-orig"
    if [ ! -f "$BACKUP" ]; then
      cp -p "$LOADED_INI" "$BACKUP" \
        || { warn "cannot back up ${LOADED_INI}; skipping it rather than risk it"; BACKUP=""; }
    fi
    if [ -n "$BACKUP" ]; then
      try_location "php.ini (prepended)" "$LOADED_INI" 2 || true
    fi
  fi

  if [ -z "$ENABLED_VIA" ]; then
    {
      echo "Could not enable ${EXT} (${SO})."
      echo
      echo "PHP reports now:"
      if [ -n "$DIAG" ]; then printf '  %s\n' "$DIAG"; else echo "  (nothing)"; fi
      echo
      echo "PHP reported BEFORE we changed anything:"
      if [ -n "$BASELINE_PROBLEMS" ]; then
        printf '  %s\n' "$BASELINE_PROBLEMS"
      else
        echo "  (clean)"
      fi
      echo
      echo "Context:"
      echo "  php             : ${PHP_API} (api ${API_NUM})"
      echo "  extension_dir   : ${EXT_DIR}"
      echo "  missing libs    : $(command -v ldd >/dev/null 2>&1 && ldd "$SO" 2>/dev/null | grep 'not found' | awk '{print $1}' | paste -sd, - || true)"
      echo
      echo "Locations tried:"
      printf "%b\n" "$ATTEMPTED"
      if [ -n "$LOADED_INI" ] && [ -f "$LOADED_INI" ]; then
        echo
        echo "Last 10 lines of ${LOADED_INI}:"
        tail -n 10 "$LOADED_INI" | sed 's/^/    /'
      fi
      echo
      echo "PHP's ini parser STOPS at the first syntax error and ignores the rest of"
      echo "that file. If the error above is above our directive, ours is discarded;"
      echo "fix that line via node > Config > etc > php.ini. If there is no error,"
      echo "point at the right build with CIVICRM_EXT_MODULE_PATH."
    } | sed 's/^/  /' >&2
    die "could not enable ${EXT}; details above."
  fi

  # The platform's php.ini may still have its own parse error. Say so, because
  # it silently discards any settings that follow it.
  if [ -n "$BASELINE_PROBLEMS" ] && [ -n "$LOADED_INI" ] && [ -f "$LOADED_INI" ]; then
    warn "${LOADED_INI} has a pre-existing parse error, which makes PHP ignore every"
    warn "setting after that line. ${EXT} is loaded because our directive is at the top."
    warn "Fix the broken line via node > Config > etc > php.ini, or those settings are lost."
  fi
elif command -v docker-php-ext-install >/dev/null 2>&1; then
  warn "${EXT}.so is not on disk; compiling it from source."
  warn "This is EPHEMERAL - it lives in the container filesystem, not the volume."
  warn "onAfterRestartNode re-runs this script, which is what keeps a box working."
  command -v apt-get >/dev/null 2>&1 || die "no apt-get and ${EXT}.so is absent; cannot build it here."
  apt-get update -qq || die "apt-get update failed (no network?)"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    libicu-dev g++ make autoconf pkg-config || die "could not install libicu-dev and build tools"
  docker-php-ext-install -j"$(nproc 2>/dev/null || echo 1)" "$EXT" || die "docker-php-ext-install ${EXT} failed"
  command -v docker-php-ext-enable >/dev/null 2>&1 && docker-php-ext-enable "$EXT" || true
  have_ext "$EXT" || die "${EXT} still not loaded after docker-php-ext-install."
else
  die "${EXT}.so is not on disk and this image has no docker-php-ext-install, so it
    cannot be enabled or built automatically. Use a PHP image that ships ${EXT},
    or upload a compiled ${EXT}.so to PHP's extension_dir and enable it in php.ini
    (dashboard > node > Config > etc > php.ini)."
fi

# The CLI reads php.ini fresh on every invocation, so the check above is real.
# A running web SAPI caches it, so nudge it - quietly, since apachectl on a
# container whose master is not up tries to START it and floods the log.
if pgrep -x apache2 >/dev/null 2>&1 || pgrep -x httpd >/dev/null 2>&1 \
   || pgrep -x php-fpm >/dev/null 2>&1; then
  log "a web SAPI is running - sending it a graceful restart to pick up php.ini"
  if command -v apachectl >/dev/null 2>&1; then
    apachectl -k graceful >/dev/null 2>&1 || service apache2 reload >/dev/null 2>&1 \
      || systemctl reload apache2 >/dev/null 2>&1 \
      || warn "could not reload the web SAPI; restart the node if ${EXT} is missing under it"
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl reload apache2 >/dev/null 2>&1 || systemctl reload httpd >/dev/null 2>&1 \
      || warn "could not reload the web SAPI; restart the node if ${EXT} is missing under it"
  else
    warn "no apachectl or systemctl here; restart the node so the web SAPI re-reads php.ini"
  fi
fi