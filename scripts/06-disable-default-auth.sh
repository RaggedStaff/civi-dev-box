#!/usr/bin/env bash
# 06-disable-default-auth.sh - run ON THE PHP CONTAINER.
#
# Removes the platform's default HTTP Basic Auth from the Apache front end.
#
# Symptom this fixes: every request to the site returns 401 and the browser
# demands credentials. Nothing in this repo configures authentication - the
# provider's Apache PHP template ships with it enabled so a fresh container is
# not left serving content to the world before you have put anything in it.
#
# Two possible sources, so both are handled:
#
#   1. Auth directives in the httpd config (AuthType / AuthUserFile /
#      "Require valid-user"), typically inside a <Directory> block for the
#      document root. Commented out, one line at a time, after a backup.
#   2. A stray .htaccess or .htpasswd sitting in the document root.
#
# Deliberately NOT touched:
#
#   * private/.htaccess and core/.htaccess. Those are ours and they must stay -
#     private/ holds civicrm.settings.php, i.e. the database credentials, and
#     "remove the auth prompt" must not become "publish the DB password".
#   * Any file outside the document root and the Apache config directories.
#
# The script reports exactly what it changed and verifies with a request, so a
# no-op is distinguishable from a silent failure.
set -euo pipefail
# shellcheck source=lib.sh
_CIVI_SELF="${BASH_SOURCE[0]:-$0}"
. "$(dirname "$_CIVI_SELF")/lib.sh" || {
  echo "civi: cannot source lib.sh (looked next to '${_CIVI_SELF}')" >&2
  echo "civi: run this script as a FILE - piping it into 'bash -s' leaves BASH_SOURCE unset." >&2
  exit 1
}

log "=== disable default basic auth ==="

APP_ROOT="${CIVICRM_APP_DIR:-${HOME}/apps/civicrm}"
CHANGED=0

# --- 1. Apache configuration --------------------------------------------------
# Comment out auth directives rather than deleting the lines, so the change is
# obvious in the file and trivially reversible by hand.
#
# Split on whitespace, not on spaces in the variable: an override holding a
# single path must not produce an empty first element.
# shellcheck disable=SC2086
CONF_DIRS="${CIVICRM_APACHE_CONF_DIRS:-/etc/httpd/conf.d /etc/httpd/conf /etc/apache2/conf-enabled /etc/apache2/sites-enabled /etc/apache2/conf.d}"
read -r -a CONF_DIR_LIST <<< "${CONF_DIRS}"

AUTH_RE='^[[:space:]]*(AuthType|AuthName|AuthUserFile|AuthBasicProvider|AuthGroupFile|Require[[:space:]]+valid-user)'

CONF_FILES=""
add_conf() { # only if it is a real file that actually contains auth directives
  [ -f "$1" ] || return 0
  if grep -qiE "$AUTH_RE" "$1"; then
    CONF_FILES="${CONF_FILES} ${1}"
  fi
}

for d in "${CONF_DIR_LIST[@]}"; do
  [ -d "$d" ] || continue
  # conf.d entries are one level deep; some layouts nest one more.
  for f in "$d"/*.conf "$d"/*/*.conf; do
    add_conf "$f"
  done
done

# The main httpd.conf is not *.conf-shaped under those names.
add_conf /etc/httpd/conf/httpd.conf
add_conf /etc/apache2/apache2.conf

# Newline-separated accumulation: word splitting on ${CONF_FILES} is safe here
# because these are fixed paths we generated ourselves, never user input.
for f in ${CONF_FILES}; do
  [ -f "$f" ] || continue
  BACKUP="${f}.civi-orig"
  [ -f "$BACKUP" ] || cp -p "$f" "$BACKUP" || {
    warn "cannot back up ${f}; skipping it"
    continue
  }
  # grep -c exits 1 when the count is 0. Under `set -e` that kills the script
  # silently the moment the last auth directive is commented out - which is
  # exactly the success case. Hence the `|| true`.
  BEFORE="$(grep -ciE "$AUTH_RE" "$f" || true)"
  BEFORE="${BEFORE:-0}"
  # Comment the directive, preserving indentation so the block stays readable.
  #
  # Two things that look right and are not:
  #   * alternation in a -E expression is a bare |, so \| demands a LITERAL pipe
  #     and matches nothing - the directive is left completely untouched
  #   * using | as the s/// delimiter then conflicts with that |, so use ,
  # Verified against GNU sed 4.8.
  sed -i -E 's,^([[:space:]]*)((AuthType|AuthName|AuthUserFile|AuthBasicProvider|AuthGroupFile)|Require[[:space:]]+valid-user)\b,#civi-default-auth# \1\2,I' "$f"
  AFTER="$(grep -ciE "$AUTH_RE" "$f" || true)"
  AFTER="${AFTER:-0}"
  if [ "$AFTER" -lt "$BEFORE" ]; then
    log "disabled $((BEFORE - AFTER)) auth directive(s) in ${f}"
    CHANGED=$((CHANGED + 1))
  fi
done

[ -n "$CONF_FILES" ] || log "no auth directives in the Apache configuration"

# --- 2. Document root ---------------------------------------------------------
# A .htpasswd in the docroot is inert once Require valid-user is gone, but it
# still holds a credential, so say where it is rather than deleting blind.
if [ -d "$APP_ROOT" ]; then
  while IFS= read -r hp; do
    [ -n "$hp" ] || continue
    warn "found a password file: ${hp}"
    warn "left in place - it is inert without an auth directive. Delete it by hand if unwanted."
  done < <(find "$APP_ROOT" -maxdepth 2 -name '.htpasswd' -type f 2>/dev/null)

  # An .htaccess in the docroot that demands auth. Ours must be exempt: private/
  # and core/ are handled by 20-fetch-civicrm.sh and have to keep denying, since
  # private/ holds civicrm.settings.php - the database credentials. Removing the
  # 401 must never become "publish the DB password".
  #
  # Compare realpath'd parent directories rather than string-matching the file
  # path, so a renamed or nested private/ is still recognised as ours.
  PRIVATE_REAL="$(readlink -f "${APP_ROOT}/private" 2>/dev/null || true)"
  CORE_REAL="$(readlink -f "${APP_ROOT}/core" 2>/dev/null || true)"
  while IFS= read -r hta; do
    [ -n "$hta" ] || continue
    grep -qiE '^[[:space:]]*(AuthType|Require[[:space:]]+valid-user)' "$hta" || continue

    # Ours are deny-only, so they never match the auth check above. This branch
    # exists so that if one ever DID gain an auth directive (say, upstream adds
    # AuthType alongside Require all denied) we refuse to touch it rather than
    # stripping a rule the operator put there on purpose.
    HTA_PARENT="$(readlink -f "$(dirname "$hta")" 2>/dev/null || true)"
    if [ -n "$PRIVATE_REAL" ] && [ "$HTA_PARENT" = "$PRIVATE_REAL" ]; then
      log "leaving ${hta} alone - our private/ deny rule, must stay"
      continue
    fi
    if [ -n "$CORE_REAL" ] && [ "$HTA_PARENT" = "$CORE_REAL" ]; then
      log "leaving ${hta} alone - our core/ deny rule, must stay"
      continue
    fi

    [ -f "${hta}.civi-orig" ] || cp -p "$hta" "${hta}.civi-orig" || true
    # Bare | for alternation, comma for the s/// delimiter. See above.
    sed -i -E 's,^([[:space:]]*)((AuthType|AuthName|AuthUserFile|AuthBasicProvider)|Require[[:space:]]+valid-user)\b,#civi-default-auth# \1\2,I' "$hta"
    log "disabled auth directives in ${hta}"
    CHANGED=$((CHANGED + 1))
  done < <(find "$APP_ROOT" -maxdepth 2 -name '.htaccess' -type f 2>/dev/null)
fi

# --- 3. Verify, then reload only if something changed -------------------------
# A no-op run must not bounce a live Apache: a needless graceful restart is
# indistinguishable from one that actually fixed something.
verify_site() {
  local url="$1" code
  command -v curl >/dev/null 2>&1 || { log "no curl; skipped the live check"; return 0; }
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 "${url}/" 2>/dev/null || echo 000)"
  case "$code" in
    401|403)
      warn "${url}/ still returns ${code}."
      warn "If 401, the auth is configured somewhere this script does not look. Find it with:"
      warn "  grep -rniE 'AuthType|Require valid-user' /etc/httpd /etc/apache2 ${url%%:*}"
      ;;
    000)
      # DNS and hairpin NAT are unreliable from inside the container; not a
      # failure of this script.
      warn "could not reach ${url}/ from the node, so the auth state is unverified here."
      ;;
    *)
      log "${url}/ returns ${code} - no auth prompt."
      ;;
  esac
}

URL="${CIVICRM_SITE_URL:-}"

if [ "$CHANGED" -eq 0 ]; then
  log "nothing to change - default auth was not enabled where this script looks"
  [ -n "$URL" ] && verify_site "$URL"
  log "=== default auth: no change needed ==="
  exit 0
fi

# The config is read at startup, so a running Apache needs a nudge.
if command -v apachectl >/dev/null 2>&1; then
  # Validate before reloading: an httpd.conf that does not parse means no
  # server at all, which is a far worse outcome than a 401.
  if apachectl -t >/dev/null 2>&1; then
    apachectl -k graceful >/dev/null 2>&1 || true
    log "graceful reload sent"
  else
    warn "apachectl -t reports the configuration is now INVALID; not reloading."
    # `|| true`: apachectl -t exits non-zero precisely BECAUSE the config is
    # broken, and that non-zero status propagates through the pipe to `set -e`,
    # killing the script here - before it can print the undo instructions that
    # matter most at this exact moment.
    apachectl -t 2>&1 | head -5 | sed 's/^/    /' || true
    for f in $CONF_FILES; do
      [ -f "${f}.civi-orig" ] && warn "restore with: cp ${f}.civi-orig ${f}"
    done
    die "Apache configuration would not parse after disabling auth."
  fi
fi

# Verify against the real thing rather than assuming it worked.
if [ -n "$URL" ]; then
  verify_site "$URL"
else
  log "no CIVICRM_SITE_URL to verify against; skipped the live check"
fi

if [ "$CHANGED" -eq 0 ]; then
  log "nothing to change - default auth was not enabled in the places this script looks"
fi
log "=== default auth disabled ==="