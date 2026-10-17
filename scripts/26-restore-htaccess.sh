#!/usr/bin/env bash
# 26-restore-htaccess.sh - put the release's .htaccess back if it was lost.
#
# Why this exists
# ---------------
# 20-fetch-civicrm.sh used to write the app .htaccess wholesale in order to add
# five php_value directives, which discarded the release's rewrite rules. The
# fix stopped that happening. It cannot undo it: on any box the old script has
# already run against, the rules are gone, and nothing else in this repo puts
# them back.
#
# The symptom does not read as a routing fault. CiviCRM Standalone is a
# front-controller app, and the release's .htaccess ends with:
#
#     RewriteCond %{REQUEST_FILENAME} !-f
#     RewriteCond %{REQUEST_FILENAME} !-d
#     RewriteCond %{REQUEST_URI} !=/favicon.ico
#     RewriteRule ^ index.php [L]
#
# Remove that and Apache stops routing anything that is not a real file:
#
#     /                         200   index.php, needs no rewrite
#     /civicrm.standalone.php   200   also a real file
#     /civicrm/login            404   exists ONLY as a rewrite
#
# The install is complete and correct throughout. Every health check in this repo
# probes one of the two URLs that keep working, which is why the box reported
# itself healthy.
#
# What this does
# --------------
# If the app .htaccess has no RewriteRule, fetch the release it was installed
# from and take .htaccess from it - the exact member, located by finding
# civicrm.standalone.php in the same tarball, not by guessing a path or matching
# a wildcard that might pick up a subdirectory's .htaccess instead. Then re-run
# the merge so the php_value block is added on top.
#
# Run on the PHP node:
#   bash 26-restore-htaccess.sh
set -euo pipefail

# shellcheck source=lib.sh
_CIVI_SELF="${BASH_SOURCE[0]:-$0}"
. "$(dirname "$_CIVI_SELF")/lib.sh" || {
  echo "civi: cannot source lib.sh (looked next to '${_CIVI_SELF}')" >&2
  exit 1
}

log "=== restore .htaccess ==="

APP_ROOT="$(detect_app_root)"
HTACCESS="${APP_ROOT}/.htaccess"
log "app root: ${APP_ROOT}"

# --- Is anything actually wrong? ---------------------------------------------
# A file with no RewriteRule at all is the failure this exists for. One that has
# the rule but lacks our block is the normal case and needs no download.
if [ -f "$HTACCESS" ] && grep -qiE '^[[:space:]]*RewriteRule' "$HTACCESS"; then
  log "${HTACCESS} already has rewrite rules - nothing to restore"
  if ! grep -qF '# BEGIN civi-dev-box' "$HTACCESS"; then
    log "adding the civi-dev-box block"
    B="$(mktemp)"
    printf '<IfModule mod_php.c>\n  php_value memory_limit 512M\n</IfModule>\n' > "$B"
    htaccess_set_block "$HTACCESS" "# BEGIN civi-dev-box - mod_php ini settings" \
      "# END civi-dev-box - mod_php ini settings" "$B"
    rm -f "$B"
  fi
  log "=== nothing needed ==="
  exit 0
fi

warn "${HTACCESS:-$APP_ROOT/.htaccess} has no RewriteRule - CiviCRM cannot route"
warn "/civicrm/* without it, so /civicrm/login returns 404 while / returns 200."

TARBALL="civicrm-${CIVICRM_VERSION}-standalone.tar.gz"
URL="${DOWNLOAD_BASE}/${TARBALL}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "downloading ${URL}"
curl -fsSL --retry 3 --retry-delay 2 "$URL" -o "${TMP}/${TARBALL}" \
  || die "failed to download ${URL}
    Set DOWNLOAD_BASE to a mirror, or restore the .htaccess by hand."

log "locating the release's own .htaccess in the archive"
# Find the tarball's root the same way 20-fetch-civicrm.sh does - by the entry
# point it must contain - then take .htaccess from that exact directory. A
# wildcard would also match any .htaccess shipped in a subdirectory, which would
# silently install the wrong file as the app's rewrite config.
ROOT_MEMBER="$(tar -tzf "${TMP}/${TARBALL}" \
  | grep -E '(^|/)civicrm\.standalone\.php$' | head -1 || true)"
[ -n "$ROOT_MEMBER" ] || die "civicrm.standalone.php not found in ${TARBALL}"
ROOT_DIR="${ROOT_MEMBER%/*}"
[ "$ROOT_DIR" != "$ROOT_MEMBER" ] || ROOT_DIR=""

if [ -n "$ROOT_DIR" ]; then
  HTA_MEMBER="${ROOT_DIR}/.htaccess"
else
  HTA_MEMBER=".htaccess"
fi
log "archive member: ${HTA_MEMBER}"

# The archive contains more than one .htaccess - civicrm-standalone/.htaccess
# and civicrm-standalone/core/packages/IDS/.htaccess among them - so this is an
# exact member name, not a wildcard. Taking the wrong one would install a
# subdirectory's deny file as the app's rewrite config.
tar -xzf "${TMP}/${TARBALL}" -C "$TMP" "$HTA_MEMBER" \
  || die "could not extract ${HTA_MEMBER} from ${TARBALL}"
[ -f "$TMP/$HTA_MEMBER" ] || die "extracted ${HTA_MEMBER} but it is not there"

grep -qiE '^[[:space:]]*RewriteRule' "$TMP/$HTA_MEMBER" \
  || die "the release's own .htaccess has no RewriteRule either - not installing it,
    because replacing one broken file with another fixes nothing.
    Check what was actually downloaded:  tar -tzf ${TARBALL} | grep htaccess"

# Keep the mangled file for comparison rather than destroying the evidence.
if [ -f "$HTACCESS" ]; then
  cp -p "$HTACCESS" "${HTACCESS}.lost" \
    && warn "the current file was kept as ${HTACCESS}.lost"
fi

cp "$TMP/$HTA_MEMBER" "$HTACCESS"
chmod 644 "$HTACCESS"
log "installed the release's .htaccess ($(stat -c %s "$HTACCESS") bytes)"

# Re-apply our block on top. Doing this in one place rather than here keeps the
# merge logic single-sourced with 20-fetch-civicrm.sh.
B="$(mktemp)"
trap 'rm -rf "$TMP" "$B"' EXIT
{
  for kv in "memory_limit 512M" "max_execution_time 240" "max_input_time 120" \
            "post_max_size 50M" "upload_max_filesize 50M"; do
    printf '<IfModule mod_php.c>\n  php_value %s %s\n</IfModule>\n' "${kv%% *}" "${kv#* }"
  done
} > "$B"

htaccess_set_block "$HTACCESS" "# BEGIN civi-dev-box - mod_php ini settings" \
  "# END civi-dev-box - mod_php ini settings" "$B" \
  || die "installed the release rules but could not merge the civi-dev-box block"

# --- Verify ------------------------------------------------------------------
# Not "the command succeeded". Prove both halves are present and readable:
# Apache reads .htaccess as www-data, and an unreadable one is 403 for every
# request in the directory - the same symptom, reached a different way.
if grep -qiE '^[[:space:]]*RewriteRule' "$HTACCESS"; then
  log "rewrite rules present"
else
  die "${HTACCESS} still has no RewriteRule after restoring it"
fi

if grep -qF '# BEGIN civi-dev-box' "$HTACCESS"; then
  log "civi-dev-box block present"
else
  warn "civi-dev-box block is missing; run 20-fetch-civicrm.sh to re-add it"
fi

MODE="$(stat -c '%a' "$HTACCESS" 2>/dev/null || echo '?')"
case "$MODE" in
  *[4567]) log "Apache can read it (mode ${MODE})" ;;
  *)       die "${HTACCESS} mode ${MODE} is not readable by other - Apache will
    403 every request in the directory. Fix with: chmod 644 ${HTACCESS}" ;;
esac

# Say how to confirm, because "/" cannot show this either way.
log "=== restore complete ==="
log "confirm with a URL that is not a file:"
log "  curl -sI https://${SITE_URL_HOST:-dev.civi.sioldata.com}/civicrm/login | head -1"
log "  expect HTTP/2 200 (or HTTP/1.1 200), not 404"
