#!/usr/bin/env bash
# core-assets-test.sh - core/ must refuse PHP WITHOUT refusing the assets.
#
# The bug this guards
# -------------------
# 20-fetch-civicrm.sh writes an .htaccess into core/ to stop PHP under mod_php
# being executed directly. It used to say, in full:
#
#     Require all denied
#
# which is a sensible-looking hardening step and is fatal, because CiviCRM
# Standalone serves its own JavaScript and CSS from /core/ -
# $civicrm_paths['civicrm.root']['url'] is <base>/core - so that rule 403s every
# asset on the login page.
#
# The symptom is the worst kind. The page still renders: the logo is a plain
# <img>, so it appears, /civicrm/login still answers 200, and only the scripts
# are missing, so the Angular login form is never built. The browser console
# says no more than:
#
#     Loading failed for the <script> with source ".../core/js/Common.js"
#
# Nothing points at a permissions rule, and a curl of the login page looks
# perfectly healthy. It reads as a broken release.
#
# So this measures the outcome through real Apache, using the REAL rule from
# lib.sh rather than a copy of it, and starting Apache the same way the platform
# does - 15-start-web.sh - because the image's own CMD never runs there.
set -uo pipefail

BOX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${IMG:-sioldata/civi-dev-box:8.5.11}"
NAME="civi-core-assets-test"
FAIL=0

pass() { printf '  [ ok ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }

# Only the container: TMP is created after the stale-container sweep, which
# would otherwise delete it on the way past.
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

command -v docker >/dev/null 2>&1 || { echo "  docker not available"; exit 0; }
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "  image $IMG not built; skipping"; exit 0; }

TMP="$(mktemp -d)"
trap 'cleanup; rm -rf "$TMP"' EXIT

# The rule under test is the one lib.sh actually produces. Reading it here means
# a future edit that reintroduces a blanket deny is caught by the 200 assertions
# below - a copy of the rule would keep passing long after the real one changed.
(cd "$BOX" && bash -c 'source scripts/lib.sh >/dev/null 2>&1; core_htaccess') > "$TMP/core.htaccess"
if [ ! -s "$TMP/core.htaccess" ]; then
  echo "  could not read core_htaccess from lib.sh"
  exit 1
fi

docker run -d --name "$NAME" --entrypoint /bin/sleep "$IMG" infinity >/dev/null 2>&1 || {
  fail "could not start container"; exit 1; }
sleep 3

# A synthetic core/ tree: CiviCRM serves several kinds of static file from it,
# plus one that must not be executed.
docker exec "$NAME" sh -c '
  mkdir -p /var/www/html/core/js /var/www/html/core/css /var/www/html/core/CRM/Unit
  echo "var x = 1;" > /var/www/html/core/js/Common.js
  echo "body{}"    > /var/www/html/core/css/civicrm.css
  echo "{\"a\":1}" > /var/www/html/core/js/config.json
  printf "%s\n" "<?php echo 12345;" > /var/www/html/core/CRM/Unit/Thing.php
' || { fail "could not build the test tree"; exit 1; }

docker cp "$TMP/core.htaccess" "$NAME:/var/www/html/core/.htaccess" >/dev/null 2>&1 || {
  fail "could not install the rule"; exit 1; }

# Start Apache exactly the way the platform does. The image's CMD is replaced by
# the container agent on Jelastic, and a bare `apachectl start` does not bring it
# up here either - see start-web-test.sh for why that is worth caring about.
docker cp "$BOX/scripts/lib.sh"         "$NAME:/tmp/lib.sh"  >/dev/null 2>&1
docker cp "$BOX/scripts/15-start-web.sh" "$NAME:/tmp/15.sh"   >/dev/null 2>&1
if ! docker exec "$NAME" bash /tmp/15.sh >/dev/null 2>&1; then
  fail "15-start-web.sh could not start Apache; the assertions below prove nothing"
  exit 1
fi
sleep 2

# Measured through Apache, not read from the file: what a browser receives is
# the only thing that matters here.
#
# The absolute URL is not decoration. `curl /path` is the FILE protocol, so it
# reads a local file, reports 000, and every assertion below would fail for a
# reason that has nothing to do with the rule under test.
http_code() {
  docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "http://127.0.0.1$1" 2>/dev/null || true
}

echo "=== assets under core/ must be served ==="
for u in /core/js/Common.js /core/css/civicrm.css /core/js/config.json; do
  c="$(http_code "$u")"
  [ "$c" = "200" ] \
    && pass "$u -> 200" \
    || fail "$u -> ${c:-no response}, expected 200. CiviCRM serves this from /core/, so a blanket deny in core/.htaccess 403s the whole UI."
done

echo
echo "=== php under core/ must not execute ==="
c="$(http_code /core/CRM/Unit/Thing.php)"
case "$c" in
  403) pass "/core/CRM/Unit/Thing.php -> 403 (refused, not executed)" ;;
  200) fail "/core/CRM/Unit/Thing.php -> 200: PHP is being executed from core/" ;;
  *)   fail "/core/CRM/Unit/Thing.php -> ${c:-no response}, expected 403" ;;
esac

# Belt and braces, and it names the cause immediately instead of leaving it to be
# inferred from a string of 403s. Anchored at column 0: the indented
# "  Require all denied" inside <FilesMatch> is correct and must not be flagged.
echo
if grep -qE '^Require all denied' "$TMP/core.htaccess"; then
  fail "core_htaccess has a directory-wide 'Require all denied' - that denies the assets too"
else
  pass "core_htaccess refuses PHP only; no directory-wide deny"
fi

echo
[ "$FAIL" -eq 0 ] && echo "  core-assets test PASSED" || echo "  core-assets test FAILED"
exit "$FAIL"
