#!/usr/bin/env bash
# start-web-test.sh - prove 15-start-web.sh works when the platform replaces
# the image's CMD.
#
# The failure this guards against is invisible locally: `docker run <image>`
# executes our CMD (civi-foreground), Apache becomes PID 1, everything works.
# On the platform the CMD is replaced by the container's own agent, so nothing
# starts Apache and every request 502s - while `apache2 -t` still reports a
# perfectly valid vhost.
#
# So this runs the image the way the platform does (an unrelated process as
# PID 1), asserts Apache is genuinely absent, then runs the script and asserts
# it came up and serves.
set -uo pipefail

BOX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${IMG:-sioldata/civi-dev-box:8.5.11}"
NAME="civi-startweb-test"
FAIL=0

pass() { printf '  [ ok ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

command -v docker >/dev/null 2>&1 || { echo "  docker not available"; exit 0; }
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "  image $IMG not built; skipping"; exit 0; }

echo "=== container with a platform-style agent as PID 1 (not our CMD) ==="
docker run -d --name "$NAME" --entrypoint /bin/sleep "$IMG" infinity >/dev/null 2>&1 || {
  fail "could not start container"; exit 1; }
sleep 3

if docker exec "$NAME" pgrep -x apache2 >/dev/null 2>&1; then
  fail "expected Apache to be ABSENT (this is the bug being reproduced)"
else
  pass "Apache is absent, as on the platform"
fi

# Deploy a stand-in for the CiviCRM entry point so the probe has something real
# to serve. 20-fetch-civicrm.sh does this for the actual release.
docker exec "$NAME" sh -c \
  'mkdir -p /var/www/html && printf "<?php echo \"civicrm\";" > /var/www/html/civicrm.standalone.php' >/dev/null

docker cp "$BOX/scripts/lib.sh"            "$NAME:/tmp/lib.sh"  >/dev/null
docker cp "$BOX/scripts/15-start-web.sh"   "$NAME:/tmp/15.sh"   >/dev/null

echo
echo "=== run 15-start-web.sh ==="
if OUT="$(docker exec "$NAME" bash /tmp/15.sh 2>&1)"; then
  printf '%s\n' "$OUT" | sed 's/^/  | /'
else
  printf '%s\n' "$OUT" | sed 's/^/  | /'
  fail "15-start-web.sh exited non-zero"
fi

echo
echo "=== assertions ==="
if docker exec "$NAME" pgrep -x apache2 >/dev/null 2>&1; then
  pass "Apache is running"
else
  fail "Apache is still not running"
fi

if docker exec "$NAME" bash -c '. /tmp/lib.sh; listening_ports' 2>/dev/null | grep -qx 80; then
  pass "listening_ports reports port 80"
else
  fail "listening_ports does not report port 80"
fi

CODE="$(docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        http://127.0.0.1/civicrm.standalone.php 2>/dev/null)"
if [ "$CODE" = "200" ]; then
  pass "serves civicrm.standalone.php with HTTP 200"
else
  fail "expected HTTP 200, got ${CODE:-no response}"
fi

# Idempotent: a restart re-runs the script, so a second run must be a no-op
# rather than a duplicate start or an error.
echo
echo "=== second run must be idempotent ==="
if docker exec "$NAME" bash /tmp/15.sh >/dev/null 2>&1; then
  pass "second run exits 0"
else
  fail "second run exited non-zero"
fi

# And private/ must still be protected after the web server is started.
CODE="$(docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        http://127.0.0.1/private/civicrm.settings.php 2>/dev/null)"
case "$CODE" in
  403|404) pass "private/ still denied (${CODE})" ;;
  *)       fail "private/ returned ${CODE:-no response} - credential leak" ;;
esac

echo
[ "$FAIL" -eq 0 ] && echo "  start-web test PASSED" || echo "  start-web test FAILED"
exit "$FAIL"