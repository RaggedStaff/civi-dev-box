#!/usr/bin/env bash
# data-dirs-test.sh - the webserver must be able to use the data volumes.
#
# The bug this guards
# -------------------
# The Dockerfile chowns $CIVICRM_DATA_DIR to www-data at BUILD time. That does
# not reach a mounted volume: Jelastic mounts one over /var/lib/civicrm-data at
# RUN time and creates it root:root with mode 0770. www-data is then neither the
# owner nor in the group, so only the "other" permission bits apply, and 0770
# grants them nothing. The webserver cannot traverse the tree, cannot read it,
# and cannot create anything in it.
#
# It does not present as a permissions problem. CiviCRM's installer reports:
#
#     settingsWritable            private/civicrm.settings.php cannot be created
#     templateCompilePathWritable private/cache cannot be created
#
# Both are fatal, so the box cannot even re-install itself - and the message
# points at nothing useful.
#
# So this reproduces the platform's state exactly (root:root 0770), then asserts
# the thing that actually matters: whether the www-data USER can create and read
# there. Asserting on `ls -l` output would only re-encode my expectation of what
# the fix produces; asking the webserver user proves the outcome.
set -uo pipefail

BOX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${IMG:-sioldata/civi-dev-box:8.5.11}"
NAME="civi-datadirs-test"
FAIL=0

pass() { printf '  [ ok ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

command -v docker >/dev/null 2>&1 || { echo "  docker not available"; exit 0; }
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "  image $IMG not built; skipping"; exit 0; }

docker run -d --name "$NAME" --entrypoint /bin/sleep "$IMG" infinity >/dev/null 2>&1 || {
  fail "could not start container"; exit 1; }
sleep 3

docker cp "$BOX/scripts/lib.sh" "$NAME:/tmp/lib.sh" >/dev/null

# --- Set up the platform's state ---------------------------------------------
# A fresh volume, root:root, mode 0770, with a docroot and a symlinked private/.
docker exec "$NAME" bash -c '
  set -e
  rm -rf /var/lib/civicrm-data /var/www/html
  mkdir -p /var/lib/civicrm-data/private /var/lib/civicrm-data/public \
           /var/lib/civicrm-data/ext /var/www/html/core
  printf "<?php echo 1;" > /var/www/html/civicrm.standalone.php
  chown -R root:root /var/lib/civicrm-data
  chmod 0770 /var/lib/civicrm-data
' >/dev/null

echo "=== the volume as the platform creates it ==="
VOLMODE="$(docker exec "$NAME" stat -c '%U:%G %a' /var/lib/civicrm-data | tr -d ' ')"
if [ "$VOLMODE" = "root:root770" ] || [ "$VOLMODE" = "root:root 770" ]; then
  pass "reproduced: ${VOLMODE}"
else
  # Not fatal - just say, because every assertion below still proves the outcome.
  printf '  [info] volume is %s, expected root:root 770\n' "$VOLMODE"
fi

BEFORE="$(docker exec "$NAME" bash -c '
  su -s /bin/bash www-data -c "touch /var/lib/civicrm-data/private/probe" 2>/dev/null \
    && { echo yes; rm -f /var/lib/civicrm-data/private/probe; } || echo no')"

if [ "$BEFORE" = "no" ]; then
  pass "www-data CANNOT create there before the fix - the bug is reproduced"
else
  fail "www-data could already create there, so this test proves nothing"
fi

# --- Run the real code path --------------------------------------------------
echo
echo "=== link_data_dirs (what 20-fetch-civicrm.sh runs) ==="
if docker exec -e CIVICRM_APP_DIR=/var/www/html "$NAME" bash -c \
     '. /tmp/lib.sh; link_data_dirs' >/dev/null 2>&1; then
  pass "link_data_dirs exits 0"
else
  fail "link_data_dirs exited non-zero"
fi

if docker exec "$NAME" test -L /var/www/html/private; then
  pass "app-side private/ is a symlink into the volume"
else
  fail "app-side private/ is not a symlink"
fi

# --- The assertions that matter ----------------------------------------------
# Ask the webserver USER, not the shell running as root. Root can do everything,
# so a test that asserts as root cannot detect this fault at all.
echo
echo "=== as www-data ==="
for d in private public ext; do
  if docker exec "$NAME" bash -c \
       "su -s /bin/bash www-data -c 'touch /var/www/html/$d/probe' 2>/dev/null"; then
    pass "www-data can create in $d/"
    docker exec "$NAME" bash -c "rm -f /var/www/html/$d/probe" >/dev/null 2>&1
  else
    fail "www-data cannot create in $d/"
  fi
done

if docker exec "$NAME" bash -c \
     "su -s /bin/bash www-data -c 'mkdir -p /var/www/html/private/cache' 2>/dev/null"; then
  pass "www-data can create private/cache (templateCompilePathWritable)"
else
  fail "www-data cannot create private/cache"
fi

# cv core:install runs as ROOT, so the settings file it writes is root-owned.
# Fixing the directory is not enough on its own: it must still be readable.
docker exec "$NAME" bash -c '
  printf "<?php \$civicrm_setting[\"dsn\"]=\"x\";" > /var/lib/civicrm-data/private/civicrm.settings.php
  chown root:root /var/lib/civicrm-data/private/civicrm.settings.php
  chmod 644 /var/lib/civicrm-data/private/civicrm.settings.php' >/dev/null

if docker exec "$NAME" bash -c \
     "su -s /bin/bash www-data -c 'head -c 5 /var/www/html/private/civicrm.settings.php' >/dev/null 2>&1"; then
  pass "www-data can READ a settings file written by root"
else
  fail "www-data cannot read the root-owned settings file"
fi

# --- And via 15-start-web.sh, which a restart relies on ----------------------
echo
echo "=== 15-start-web.sh repairs this too (suspend/start path) ==="
docker exec "$NAME" bash -c '
  rm -rf /var/lib/civicrm-data
  mkdir -p /var/lib/civicrm-data/private /var/lib/civicrm-data/public /var/lib/civicrm-data/ext
  chown -R root:root /var/lib/civicrm-data; chmod 0770 /var/lib/civicrm-data' >/dev/null
docker cp "$BOX/scripts/15-start-web.sh" "$NAME:/tmp/15.sh" >/dev/null

if docker exec "$NAME" bash /tmp/15.sh >/dev/null 2>&1; then
  pass "15-start-web.sh exits 0"
else
  fail "15-start-web.sh exited non-zero"
fi

if docker exec "$NAME" bash -c \
     "su -s /bin/bash www-data -c 'touch /var/www/html/private/probe' 2>/dev/null"; then
  pass "www-data can create after 15-start-web.sh alone"
  docker exec "$NAME" bash -c "rm -f /var/www/html/private/probe" >/dev/null 2>&1
else
  fail "www-data still cannot create after 15-start-web.sh"
fi

# --- The settings file must not be webserver-writable -------------------------
# CiviCRM checks this and only warns, so a regression here is silent until it
# appears as a warning during install. The recursive chown above hands the file
# to www-data; ensure_data_dirs is supposed to take it back.
echo
echo "=== civicrm.settings.php must not be writable by the webserver ==="
docker exec "$NAME" bash -c '
  set -e
  # Leave the file exactly as the recursive chown would: owned by www-data, and
  # writable because it is the owner.
  printf "<?php \$civicrm_setting[\"dsn\"]=\"stub\";" > /var/lib/civicrm-data/private/civicrm.settings.php
  chown www-data:www-data /var/lib/civicrm-data/private/civicrm.settings.php
  chmod 664 /var/lib/civicrm-data/private/civicrm.settings.php' >/dev/null

docker exec -e CIVICRM_APP_DIR=/var/www/html "$NAME" bash -c \
  '. /tmp/lib.sh; ensure_data_dirs' >/dev/null 2>&1

OWN="$(docker exec "$NAME" stat -c '%U:%G' /var/lib/civicrm-data/private/civicrm.settings.php | tr -d ' ')"
if [ "$OWN" = "root:root" ]; then
  pass "settings file is root:root, not www-data"
else
  fail "settings file owner is ${OWN}, expected root:root (CiviCRM warns otherwise)"
fi

if docker exec "$NAME" bash -c \
     "su -s /bin/bash www-data -c 'head -c 5 /var/www/html/private/civicrm.settings.php' >/dev/null 2>&1"; then
  pass "www-data can still READ it"
else
  fail "www-data cannot read the settings file - the site will not boot"
fi

# The check CiviCRM makes: is_writable() as the webserver user must be false.
if docker exec "$NAME" bash -c \
     "su -s /bin/bash www-data -c 'echo x >> /var/www/html/private/civicrm.settings.php' 2>/dev/null"; then
  fail "www-data CAN write it - CiviCRM reports settingsWritable"
  docker exec "$NAME" bash -c \
    'printf "<?php \$civicrm_setting[\"dsn\"]=\"stub\";" > /var/lib/civicrm-data/private/civicrm.settings.php' >/dev/null 2>&1
else
  pass "www-data cannot write it (settingsWritable would pass)"
fi

# --- Can the webserver SEE the settings file? --------------------------------
# This is the exact condition that decides between the CiviCRM site and its web
# installer: WebEntrypoint::checkCiviInstalled() is `defined('CIVICRM_SETTINGS_PATH')`,
# set only when bootSettings()'s file_exists() succeeds AS THE WEB USER. Root can
# see every file, so root's view cannot prove this - which is how an install
# reports success while the browser still shows the installer.
echo
echo "=== settings_visible_to_web (the installer-screen check) ==="
if docker exec -e CIVICRM_APP_DIR=/var/www/html "$NAME" bash -c \
     '. /tmp/lib.sh; settings_visible_to_web'; then
  pass "www-data can see the settings file -> CiviCRM serves the site"
else
  fail "www-data cannot see the settings file -> CiviCRM would show its installer"
fi

# Reproduce the platform's original volume state around the file. Note it is the
# DIRECTORY that matters, not the file's own mode: file_exists() only stats, so
# a mode-000 file still "exists" and CiviCRM would serve a 500 rather than the
# installer. A parent directory www-data cannot traverse is the real condition.
docker exec "$NAME" bash -c \
  'chown root:root /var/lib/civicrm-data/private && chmod 0770 /var/lib/civicrm-data/private' >/dev/null
if docker exec -e CIVICRM_APP_DIR=/var/www/html "$NAME" bash -c \
     '. /tmp/lib.sh; settings_visible_to_web'; then
  fail "reported visible through a 0770 root:root directory - it cannot detect the installer condition"
else
  pass "reports invisible when www-data cannot traverse private/ (the real bug)"
fi

docker exec "$NAME" bash -c \
  'chown www-data:www-data /var/lib/civicrm-data/private && chmod 2770 /var/lib/civicrm-data/private' >/dev/null

echo
[ "$FAIL" -eq 0 ] && echo "  data-dirs test PASSED" || echo "  data-dirs test FAILED"
exit "$FAIL"
