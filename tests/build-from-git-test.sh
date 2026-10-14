#!/usr/bin/env bash
# build-from-git-test.sh - prove the git build path works inside the box image.
#
# This is deliberately NOT run in the local sandbox: the sandbox's PHP lacks
# ext-dom, so `composer install` fails there for a reason that has nothing to
# do with the box. The image is the environment this actually ships in, so the
# test runs in the image.
#
# Checks that matter:
#   * a clean clone builds (composer install + the extension's own script)
#   * the archive lands where we think it does
#   * the extension's SHA256SUMS verifies
#   * running it twice works - build-release.sh refuses to reuse its output
#     directory, which made every rebuild after the first fail
set -uo pipefail

BOX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${IMG:-sioldata/civi-dev-box:8.5.11}"
NAME="civi-gitbuild-test"
FAIL=0
pass() { printf '  [ ok ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }

command -v docker >/dev/null 2>&1 || { echo "  docker not available"; exit 0; }
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "  image $IMG not built; skipping"; exit 0; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker run -d --name "$NAME" --entrypoint /bin/sleep "$IMG" infinity >/dev/null 2>&1 || {
  fail "could not start container"; exit 1; }
sleep 3

for f in lib.sh 45-build-from-git.sh read-attr.php 45-deploy-archive.sh; do
  docker cp "$BOX/scripts/$f" "$NAME:/tmp/$f" >/dev/null
done

# No network stub: this test is about the real clone. If GitHub is unreachable
# it should fail loudly rather than pass vacuously.

run_once() {
  docker exec "$NAME" bash -c 'cd /tmp && bash /tmp/45-build-from-git.sh --branch main 2>&1'
}

echo "=== build from a clean clone (inside the image) ==="
OUT="$(run_once)"
printf '%s\n' "$OUT" | grep -E 'at commit|SHA256SUMS|archive:' | sed 's/^/  | /'

if printf '%s' "$OUT" | grep -q 'at commit [0-9a-f]'; then
  pass "cloned and checked out a commit"
else
  fail "no commit resolved - the clone or fetch failed"
fi

if printf '%s' "$OUT" | grep -q 'SHA256SUMS verified'; then
  pass "the extension's SHA256SUMS verified"
else
  fail "checksums did not verify"
fi

if printf '%s' "$OUT" | grep -qE 'archive: .*dfc_civicrm-[0-9.]+\.tar\.gz'; then
  pass "archive located"
else
  fail "no archive reported"
fi

# The deployer will stop here - this container has no CiviCRM site - and that is
# correct. What must NOT appear is the stale-output complaint.
if printf '%s' "$OUT" | grep -qi 'already exists'; then
  fail "build-release.sh refused to reuse its output directory - rebuilds will fail"
else
  pass "no stale-output error"
fi

echo
echo "=== a second build must work too ==="
OUT2="$(run_once)"
if printf '%s' "$OUT2" | grep -qi 'already exists'; then
  fail "second build hit the stale-output guard"
elif printf '%s' "$OUT2" | grep -q 'SHA256SUMS verified'; then
  pass "second build succeeded and verified"
else
  fail "second build did not complete"
  printf '%s\n' "$OUT2" | tail -12 | sed 's/^/         /'
fi

echo
echo "=== info.xml key must match the extension key we deploy under ==="
K="$(docker exec "$NAME" php /tmp/read-attr.php \
        /var/lib/civicrm-data/build/dfc-civicrm/info.xml key)"
if [ "$K" = "dfc_civicrm" ]; then
  pass "info.xml key = $K"
else
  fail "info.xml key is '$K', expected dfc_civicrm"
fi

echo
[ "$FAIL" -eq 0 ] && echo "  build-from-git test PASSED" || echo "  build-from-git test FAILED"
exit "$FAIL"