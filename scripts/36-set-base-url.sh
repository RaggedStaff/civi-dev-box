#!/usr/bin/env bash
# 36-set-base-url.sh - re-point an installed CiviCRM at a different base URL.
#
# Why this exists
# ---------------
# `cv core:install --cms-base-url` bakes the base URL into civicrm.settings.php
# in SEVEN places: CIVICRM_UF_BASEURL plus six $civicrm_paths[*]['url'] entries
# that every asset URL is built from:
#
#     $civicrm_paths['cms.root']['url']         = '<base>'
#     $civicrm_paths['civicrm.files']['url']    = '<base>/public'
#     $civicrm_paths['civicrm.root']['url']     = '<base>/core'
#     $civicrm_paths['civicrm.vendor']['url']   = '<base>/core/vendor'
#     $civicrm_paths['civicrm.bower']['url']    = '<base>/core/bower_components'
#     $civicrm_paths['civicrm.packages']['url'] = '<base>/core/packages'
#     define('CIVICRM_UF_BASEURL', '<base>')
#
# Moving the site to another host without updating all of them leaves the page
# loading from the new host while every script and stylesheet is fetched from the
# old one. If the certificate does not match that old host, the browser refuses
# those subresources - so the static parts render (the CiviCRM logo) and the
# Angular login form never appears. That looks like a broken install when the
# install is fine and only the asset host is wrong.
#
# Usage:
#   bash 36-set-base-url.sh https://civi-dev.jcloud-ver-jpe.ik-server.com
#   bash 36-set-base-url.sh            # CIVICRM_SITE_URL, then CIVICRM_ENV_URL
set -euo pipefail
# shellcheck source=lib.sh
_CIVI_SELF="${BASH_SOURCE[0]:-$0}"
. "$(dirname "$_CIVI_SELF")/lib.sh" || {
  echo "civi: cannot source lib.sh (looked next to '${_CIVI_SELF}')" >&2
  echo "civi: run this script as a FILE - piping it into 'bash -s' leaves BASH_SOURCE unset." >&2
  exit 1
}

log "=== set civicrm base url ==="

# CIVICRM_ENV_URL is the environment URL the manifest passes in. NOT ${env.url}:
# that is JPS syntax, and bash rejects parameter names containing '.' outright.
NEW_URL="${1:-${CIVICRM_SITE_URL:-${CIVICRM_ENV_URL:-}}}"
[ -n "$NEW_URL" ] || die "usage: bash $0 https://host[:port]
    (or set CIVICRM_SITE_URL / CIVICRM_ENV_URL)"
NEW_URL="${NEW_URL%/}"
case "$NEW_URL" in
  http://*|https://*) ;;
  *) die "the base URL must start with http:// or https:// (got '${NEW_URL}')" ;;
esac

APP_ROOT="$(detect_app_root)"
CIVICRM_APP_DIR="$APP_ROOT"
SETTINGS="${APP_ROOT}/private/civicrm.settings.php"
[ -f "$SETTINGS" ] || die "no settings file at ${SETTINGS}
    Run 30-install-civicrm.sh first."

# Read the value the way CiviCRM reads it - by loading the file, never by
# parsing the source. The file is PHP and its formatting varies by release.
read_base_url() {
  php -r '
    $f = $argv[1];
    $tmp = @tempnam(sys_get_temp_dir(), "bu");
    if (!$tmp) { exit(1); }
    $child = "require \$argv[1];"
           . " file_put_contents(\$argv[2], defined(\"CIVICRM_UF_BASEURL\") ? CIVICRM_UF_BASEURL : \"\");";
    exec(escapeshellarg(PHP_BINARY) . " -d display_errors=0 -d error_reporting=0 -r "
        . escapeshellarg($child) . " " . escapeshellarg($f) . " " . escapeshellarg($tmp) . " 2>/dev/null");
    $v = @file_get_contents($tmp);
    @unlink($tmp);
    if (!is_string($v)) { exit(1); }
    echo $v;
  ' "$1" 2>/dev/null
}

OLD_URL="$(read_base_url "$SETTINGS")" \
  || die "could not load ${SETTINGS} to read CIVICRM_UF_BASEURL"
[ -n "$OLD_URL" ] || die "${SETTINGS} does not define CIVICRM_UF_BASEURL.
    Run 30-install-civicrm.sh first."
OLD_URL="${OLD_URL%/}"

if [ "$OLD_URL" = "$NEW_URL" ]; then
  log "base URL is already ${NEW_URL} - nothing to do"
  exit 0
fi

log "current:  ${OLD_URL}"
log "new:      ${NEW_URL}"

# Keep a copy: this rewrites the file that holds the database credentials and the
# encryption keys. Same reasoning as .htaccess.lost in 26-restore-htaccess.sh.
BACKUP="${SETTINGS}.preurl.bak"
cp -p "$SETTINGS" "$BACKUP" \
  || warn "could not back up ${SETTINGS}"
log "backup:   ${BACKUP}"

# Literal replacement, not sed. A URL contains / . : ? and &, every one of which
# means something to a regex, and a missed occurrence stays invisible until a
# browser refuses the asset.
#
# Returns the number of replacements on stdout; exits 3 when the literal is not
# present at all (so an optional second pass can be skipped).
replace_literal() {
  php -r '
    $f = $argv[1]; $old = $argv[2]; $new = $argv[3];
    $s = file_get_contents($f);
    if ($s === false) { fwrite(STDERR, "cannot read $f\n"); exit(1); }
    $n = substr_count($s, $old);
    if ($n === 0) { exit(3); }
    if (file_put_contents($f, str_replace($old, $new, $s)) === false) {
      fwrite(STDERR, "cannot write $f\n"); exit(1);
    }
    echo $n;
  ' "$1" "$2" "$3"
}

N="$(replace_literal "$SETTINGS" "$OLD_URL" "$NEW_URL")" \
  || die "rewrite failed - ${SETTINGS} is unchanged"

log "replaced ${N} occurrence(s) of ${OLD_URL}"

# CiviCRM renders some resource URLs with the scheme of the incoming request, so
# the same host can appear as both http:// and https://. Replacing only the exact
# old base URL would leave the other form pointing at the old host, and the
# symptom would be identical - the browser refuses those scripts.
ALT_URL=""
case "$OLD_URL" in
  http://*)  ALT_URL="https://${OLD_URL#http://}" ;;
  https://*) ALT_URL="http://${OLD_URL#https://}" ;;
esac
if [ -n "$ALT_URL" ]; then
  if N2="$(replace_literal "$SETTINGS" "$ALT_URL" "$NEW_URL")"; then
    log "replaced ${N2} occurrence(s) of the other-scheme form ${ALT_URL}"
  fi
fi

# Verify by loading, not by reading the source: this is what CiviCRM will see.
GOT="$(read_base_url "$SETTINGS")" \
  || die "could not reload ${SETTINGS} after the rewrite"
[ "$GOT" = "$NEW_URL" ] \
  || die "after the rewrite CIVICRM_UF_BASEURL is '${GOT}', expected '${NEW_URL}'"

# Anything still pointing at the old host is an asset URL that will fail in the
# browser exactly as before, so treat it as a failure rather than a note.
for u in "$OLD_URL" "$ALT_URL"; do
  [ -n "$u" ] || continue
  if grep -qF -- "$u" "$SETTINGS"; then
    die "the old URL still appears in ${SETTINGS} after the rewrite.
    Inspect it with:
      grep -nF '${u}' ${SETTINGS}"
  fi
done

log "CIVICRM_UF_BASEURL and every \$civicrm_paths url now point at ${NEW_URL}"

# CiviCRM caches rendered pages and resource URLs; flush so nothing keeps handing
# out the old host. Not fatal if cv is missing - the settings file is already
# correct, and the cache expires anyway.
CV="$(ensure_cv 2>/dev/null || true)"
if [ -n "$CV" ] && command -v "$CV" >/dev/null 2>&1; then
  if ( cd "$APP_ROOT" && "$CV" flush >/dev/null 2>&1 ); then
    log "flushed civicrm caches"
  else
    warn "cv flush failed - run it by hand: cd ${APP_ROOT} && cv flush"
  fi
else
  warn "cv not found - clear caches by hand: cd ${APP_ROOT} && cv flush"
fi

log "=== base url set: ${NEW_URL} ==="
