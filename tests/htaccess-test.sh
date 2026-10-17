#!/usr/bin/env bash
# htaccess-test.sh - prove 20-fetch-civicrm.sh does not destroy the release's
# routing.
#
# The bug this guards: the script wrote the app .htaccess wholesale to add
# php_value directives, discarding the RewriteRule that routes /civicrm/* to
# civicrm.standalone.php.
#
# It reads as a broken install, not a routing fault, because the two URLs that
# still worked are the two that need no rewriting:
#
#     /                         200   index.php - a real file
#     /civicrm.standalone.php   200   also a real file
#     /civicrm/login            404   exists ONLY as a rewrite
#
# So the assertion has to be about a URL that is not a file. Probing "/" or the
# entry point - as 15-start-web.sh does - cannot catch this class of fault at
# all, which is why the box came up green with its routing gone.
set -uo pipefail

BOX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${IMG:-sioldata/civi-dev-box:8.5.11}"
NAME="civi-htaccess-test"
FAIL=0

pass() { printf '  [ ok ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

command -v docker >/dev/null 2>&1 || { echo "  docker not available"; exit 0; }
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "  image $IMG not built; skipping"; exit 0; }

echo "=== unit: htaccess_set_block preserves other authors' rules ==="
docker run -d --name "$NAME" --entrypoint /bin/sleep "$IMG" infinity >/dev/null 2>&1 || {
  fail "could not start container"; exit 1; }
sleep 3

docker cp "$BOX/scripts/lib.sh" "$NAME:/tmp/lib.sh" >/dev/null

# `docker exec -i` is required for these. Without -i the container's stdin is
# closed, so `cat > file` reads EOF immediately and writes a ZERO-BYTE file -
# silently. Every fixture below then passes vacuously, which is how this test
# first reported "the RewriteRule was destroyed" for a file that had never been
# written.
#
# The rewrite rules the CiviCRM 6.18.2 Standalone release actually ships, copied
# verbatim from civicrm-6.18.2-standalone.tar.gz rather than reconstructed.
#
# Note the target: index.php, NOT civicrm.standalone.php. The entry point's name
# strongly suggests it is the rewrite target and the assumption is easy to make -
# it is wrong, and it was wrong in this test before the real tarball was
# unpacked. /civicrm/login falls through to index.php, the Standalone front
# controller, which then routes into CiviCRM.
docker exec -i "$NAME" bash -c 'cat > /tmp/release.htaccess' <<'HTA'
DirectoryIndex index.php index.html index.htm

# Make CiviCRM handle any 404 errors.
ErrorDocument 404 /index.php

# Don't show directory listings for URLs which map to a directory.
Options -Indexes

<IfModule mod_rewrite.c>
  RewriteEngine on

  RewriteCond %{REQUEST_FILENAME} !-f
  RewriteCond %{REQUEST_FILENAME} !-d
  RewriteCond %{REQUEST_URI} !=/favicon.ico
  RewriteRule ^ index.php [L]
</IfModule>
HTA

docker exec -i "$NAME" bash -c 'cat > /tmp/block' <<'BLK'
<IfModule mod_php.c>
  php_value memory_limit 512M
</IfModule>
BLK

# Guard the fixtures themselves. A vacuous pass is worse than a failure: it
# records confidence in a thing that was never tested.
if docker exec "$NAME" grep -q 'RewriteRule' /tmp/release.htaccess \
   && docker exec "$NAME" grep -q 'php_value' /tmp/block; then
  pass "fixtures are in place"
else
  fail "fixtures did not land in the container - assertions below prove nothing"
fi

if docker exec "$NAME" bash -c '
    . /tmp/lib.sh
    htaccess_set_block /tmp/release.htaccess "# BEGIN civi-dev-box" "# END civi-dev-box" /tmp/block'; then
  pass "htaccess_set_block exits 0"
else
  fail "htaccess_set_block exited non-zero"
fi

if docker exec "$NAME" grep -q 'RewriteRule \^ index.php \[L\]' /tmp/release.htaccess; then
  pass "the release's RewriteRule to index.php survives"
else
  fail "the release's RewriteRule was destroyed"
fi

if docker exec "$NAME" grep -q 'php_value memory_limit 512M' /tmp/release.htaccess; then
  pass "our php_value block was added"
else
  fail "our php_value block is missing"
fi

BEFORE_LINES="$(docker exec "$NAME" sh -c 'wc -l < /tmp/release.htaccess' | tr -d ' ')"
docker exec "$NAME" bash -c '
  . /tmp/lib.sh
  htaccess_set_block /tmp/release.htaccess "# BEGIN civi-dev-box" "# END civi-dev-box" /tmp/block' >/dev/null 2>&1
AFTER_LINES="$(docker exec "$NAME" sh -c 'wc -l < /tmp/release.htaccess' | tr -d ' ')"

if [ "$BEFORE_LINES" = "$AFTER_LINES" ]; then
  pass "second run is idempotent (${BEFORE_LINES} lines, unchanged)"
else
  fail "second run changed the file: ${BEFORE_LINES} -> ${AFTER_LINES} lines"
fi

NCOUNT="$(docker exec "$NAME" grep -c 'BEGIN civi-dev-box' /tmp/release.htaccess | tr -d ' ')"
if [ "$NCOUNT" = "1" ]; then
  pass "exactly one managed block after two runs"
else
  fail "expected 1 managed block, found ${NCOUNT}"
fi

if docker exec "$NAME" bash -c '. /tmp/lib.sh; htaccess_set_block /tmp/absent.htaccess "# BEGIN civi-dev-box" "# END civi-dev-box" /tmp/block' \
   && docker exec "$NAME" grep -q 'php_value' /tmp/absent.htaccess; then
  pass "creates the file when none exists"
else
  fail "did not create a missing .htaccess"
fi

# --- Now the real script, end to end ----------------------------------------
echo
echo "=== integration: the shipped 20-fetch-civicrm.sh, against real Apache ==="
docker exec "$NAME" bash -c 'rm -rf /var/www/html /var/lib/civicrm-data
mkdir -p /var/www/html/core /var/lib/civicrm-data
cd /var/www/html
printf "<?php echo \"index\";"    > index.php
printf "<?php echo \"standalone\";" > civicrm.standalone.php
cat > .htaccess <<'"'"'HTA'"'"'
DirectoryIndex index.php
ErrorDocument 404 /index.php
Options -Indexes

<IfModule mod_rewrite.c>
  RewriteEngine on
  RewriteCond %{REQUEST_FILENAME} !-f
  RewriteCond %{REQUEST_FILENAME} !-d
  RewriteCond %{REQUEST_URI} !=/favicon.ico
  RewriteRule ^ index.php [L]
</IfModule>
HTA
'

docker cp "$BOX/scripts/20-fetch-civicrm.sh" "$NAME:/tmp/20.sh" >/dev/null

if OUT="$(docker exec -e CIVICRM_APP_DIR=/var/www/html -e CIVICRM_DATA_DIR=/var/lib/civicrm-data \
          "$NAME" bash /tmp/20.sh 2>&1)"; then
  printf '%s\n' "$OUT" | grep -E '^\[civi\]' | sed 's/^/  | /'
  pass "20-fetch-civicrm.sh exited 0 without downloading (release already present)"
else
  printf '%s\n' "$OUT" | sed 's/^/  | /'
  fail "20-fetch-civicrm.sh exited non-zero"
fi

if docker exec "$NAME" grep -q 'RewriteRule' /var/www/html/.htaccess; then
  pass "the release RewriteRule survived the real script"
else
  fail "the real script destroyed the RewriteRule"
fi

if docker exec "$NAME" grep -q 'php_value memory_limit 512M' /var/www/html/.htaccess; then
  pass "the real script still added its php_value block"
else
  fail "the real script did not add its php_value block"
fi

# Apache reads .htaccess as www-data. If it cannot, AllowOverride makes Apache
# answer 403 for every request in the directory - which is indistinguishable
# from a lost rewrite rule, and is how this file first broke. mktemp creates
# 0600, so without an explicit chmod the merge writes an unreadable file.
#
# The "other" permission digit is a bitmask: r=4 w=2 x=1. Readable by other is
# therefore 4, 5, 6 or 7 - the opposite of testing for an odd digit.
HTA_MODE="$(docker exec "$NAME" stat -c '%a' /var/www/html/.htaccess 2>/dev/null | tr -d ' ')"
case "$HTA_MODE" in
  *[4567]) pass "Apache can read the merged .htaccess (mode ${HTA_MODE})" ;;
  *)       fail ".htaccess mode ${HTA_MODE:-unknown} is not readable by other - Apache would 403 every request" ;;
esac

echo
echo "=== the assertion that matters: a URL that is not a file ==="
docker cp "$BOX/scripts/15-start-web.sh" "$NAME:/tmp/15.sh" >/dev/null
if OUT="$(docker exec "$NAME" bash /tmp/15.sh 2>&1)"; then
  pass "15-start-web.sh brought Apache up"
else
  # Do not swallow this: it is the only place the 403-vs-404 distinction shows.
  printf '%s\n' "$OUT" | sed 's/^/  | /'
  fail "15-start-web.sh could not start Apache"
fi
sleep 2

CODE="$(docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        http://127.0.0.1/civicrm/login 2>/dev/null)"
if [ "$CODE" = "200" ]; then
  pass "/civicrm/login -> 200 (the front controller is reachable)"
else
  fail "/civicrm/login -> ${CODE:-no response}, expected 200. Routing is broken."
fi

CODE="$(docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        http://127.0.0.1/ 2>/dev/null)"
if [ "$CODE" = "200" ]; then
  pass "/ -> 200"
else
  fail "/ -> ${CODE:-no response}, expected 200"
fi

# --- The diagnostic and the repair -------------------------------------------
# A fault is only genuinely fixed if something can both detect it and repair it.
# Every other health check in this repo probes a URL that needs no rewriting, so
# why-routing is the first thing that can see this class of failure at all.
echo
echo "=== 96-why-routing.sh must SEE a broken rewrite ==="
docker cp "$BOX/scripts/96-why-routing.sh" "$NAME:/tmp/96.sh" >/dev/null
docker exec "$NAME" bash -c 'printf "# Managed by civi-dev-box\n  php_value memory_limit 512M\n" > /var/www/html/.htaccess'

# Redirects below run on the HOST, so the log is a host file - grep it there.
# Reading it with `docker exec ... grep ... /tmp/...` looks inside the container
# instead, finds nothing, and fails every assertion for the wrong reason.
BROKEN_LOG="$(mktemp)"
if docker exec "$NAME" bash /tmp/96.sh >"$BROKEN_LOG" 2>&1; then
  fail "why-routing exited 0 on a .htaccess with no RewriteRule"
else
  pass "why-routing exits non-zero when the rewrite is gone"
fi

if grep -q 'no RewriteRule' "$BROKEN_LOG"; then
  pass "why-routing names the missing rewrite as the cause"
else
  fail "why-routing did not identify the missing RewriteRule"
fi

if grep -q 'restore-htaccess' "$BROKEN_LOG"; then
  pass "why-routing points at the repair"
else
  fail "why-routing did not say how to repair it"
fi

echo
echo "=== 26-restore-htaccess.sh must REPAIR it (downloads the release) ==="
docker cp "$BOX/scripts/26-restore-htaccess.sh" "$NAME:/tmp/26.sh" >/dev/null
RESTORE_LOG="$(mktemp)"
if docker exec -e CIVICRM_APP_DIR=/var/www/html -e CIVICRM_VERSION="${CIVICRM_VERSION:-6.18.2}" \
     "$NAME" bash /tmp/26.sh >"$RESTORE_LOG" 2>&1; then
  pass "restore-htaccess exits 0"
else
  sed 's/^/  | /' "$RESTORE_LOG" | tail -8
  fail "restore-htaccess exited non-zero"
fi
rm -f "$BROKEN_LOG" "$RESTORE_LOG"

if docker exec "$NAME" grep -q 'RewriteRule' /var/www/html/.htaccess; then
  pass "the release's rewrite rules are back"
else
  fail "restore did not put the rewrite rules back"
fi

if docker exec "$NAME" test -f /var/www/html/.htaccess.lost; then
  pass "the mangled file was kept as .htaccess.lost (evidence preserved)"
else
  fail "restore destroyed the broken file instead of keeping it"
fi

if docker exec "$NAME" bash /tmp/96.sh >/dev/null 2>&1; then
  pass "why-routing reports healthy after the repair"
else
  fail "why-routing still reports broken after the repair"
fi

CODE="$(docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        http://127.0.0.1/civicrm/login 2>/dev/null)"
if [ "$CODE" = "200" ]; then
  pass "/civicrm/login -> 200 after repair"
else
  fail "/civicrm/login -> ${CODE:-no response} after repair"
fi

echo
[ "$FAIL" -eq 0 ] && echo "  htaccess test PASSED" || echo "  htaccess test FAILED"
exit "$FAIL"
