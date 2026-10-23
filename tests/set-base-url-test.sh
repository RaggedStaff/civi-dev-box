#!/usr/bin/env bash
# set-base-url-test.sh - 36-set-base-url.sh must move EVERY baked-in URL.
#
# The failure this guards
# -----------------------
# cv core:install writes the base URL into civicrm.settings.php seven times. If a
# rebase updates only CIVICRM_UF_BASEURL (the obvious one) the page loads from the
# new host while the scripts and stylesheets still come from the old one. With a
# certificate that does not match, the browser refuses those subresources: the
# CiviCRM logo renders and the Angular login form never appears. It looks like a
# broken install and is really one missing string replacement.
#
# So this asserts the count, not just "the obvious variable changed".
set -uo pipefail

BOX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf '  [ ok ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }

OLD="https://old.example.org"
NEW="https://new.example.org"

# A stub cv: the script flushes caches, which is irrelevant here but must not
# fail the run.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/cv" <<'STUB'
#!/usr/bin/env bash
[ -n "${CV_LOG:-}" ] && printf '%s\n' "$*" >> "$CV_LOG"
exit 0
STUB
chmod +x "$TMP/bin/cv"

# Start from the real lib.sh and override only what depends on the environment.
cp "$BOX/scripts/lib.sh" "$TMP/lib.sh"
cat >> "$TMP/lib.sh" <<STUB

# --- overrides for this test ---
detect_app_root() { printf '%s' "\$APP"; }
ensure_cv()       { printf %s $TMP/bin/cv; }
ensure_data_dirs() { :; }
STUB

cp "$BOX/scripts/36-set-base-url.sh" "$TMP/36.sh"

make_app() {
  local d="$TMP/$1"
  mkdir -p "$d/private"
  printf '<?php\n' > "$d/civicrm.standalone.php"
  cat > "$d/private/civicrm.settings.php" <<'PHPX'
<?php
define('CIVICRM_UF', 'Standalone');
$civicrm_paths['cms.root']['url'] = 'https://old.example.org';
$civicrm_paths['civicrm.files']['url'] = 'https://old.example.org/public';
$civicrm_paths['civicrm.root']['url'] = 'https://old.example.org/core';
$civicrm_paths['civicrm.vendor']['url'] = 'https://old.example.org/core/vendor';
$civicrm_paths['civicrm.bower']['url'] = 'https://old.example.org/core/bower_components';
$civicrm_paths['civicrm.packages']['url'] = 'https://old.example.org/core/packages';
if (!defined('CIVICRM_UF_BASEURL')) {
  define('CIVICRM_UF_BASEURL', 'https://old.example.org');
}
define('CIVICRM_SITE_KEY', 'KEEP-ME-INTACT');
PHPX
  printf '%s' "$d"
}

run() {  # $1 = app root, rest = args
  local d="$1"; shift
  env -u CIVICRM_SITE_URL -u CIVICRM_ENV_URL \
    APP="$d" CV_LOG="$TMP/cv.log" CIVICRM_APP_DIR="$d" \
    bash "$TMP/36.sh" "$@" >"$TMP/out" 2>&1
}

run_env() {  # $1 = app root, rest = extra env assignments
  local d="$1"; shift
  env -u CIVICRM_SITE_URL -u CIVICRM_ENV_URL \
    APP="$d" CV_LOG="$TMP/cv.log" CIVICRM_APP_DIR="$d" "$@" \
    bash "$TMP/36.sh" >"$TMP/out" 2>&1
}

echo "=== rebase to a new host ==="
APP1="$(make_app one)"
if run "$APP1" "$NEW"; then
  pass "exits 0"
else
  sed 's/^/  | /' "$TMP/out" | tail -8
  fail "exited non-zero"
fi

GOT="$(php -r 'require $argv[1]; echo CIVICRM_UF_BASEURL;' "$APP1/private/civicrm.settings.php" 2>/dev/null)"
[ "$GOT" = "$NEW" ] \
  && pass "CIVICRM_UF_BASEURL is ${NEW}" \
  || fail "CIVICRM_UF_BASEURL is '${GOT}', expected '${NEW}'"

if grep -qF -- "$OLD" "$APP1/private/civicrm.settings.php"; then
  fail "the old host still appears - an asset URL would still be fetched from it"
else
  pass "no occurrence of the old host remains"
fi

NEWCOUNT="$(grep -cF -- "$NEW" "$APP1/private/civicrm.settings.php")"
[ "$NEWCOUNT" = "7" ] \
  && pass "all 7 baked-in URLs moved (1 UF_BASEURL + 6 civicrm_paths)" \
  || fail "found ${NEWCOUNT} occurrences of the new host, expected 7 - a path was missed"

if grep -qF 'KEEP-ME-INTACT' "$APP1/private/civicrm.settings.php"; then
  pass "unrelated settings are untouched"
else
  fail "the rewrite damaged unrelated content"
fi

if grep -qF -- "$OLD" "$APP1/private/civicrm.settings.php.preurl.bak"; then
  pass "the previous file was kept as .preurl.bak"
else
  fail "no backup of the previous settings file"
fi

if grep -qx 'flush' "$TMP/cv.log" 2>/dev/null; then
  pass "caches were flushed"
else
  fail "cv flush was not run - cached resource URLs may keep using the old host"
fi

echo
echo "=== rebasing to the URL it already has ==="
APP2="$(make_app two)"
BEFORE="$(sha256sum "$APP2/private/civicrm.settings.php" | awk '{print $1}')"
if run "$APP2" "$OLD"; then
  AFTER="$(sha256sum "$APP2/private/civicrm.settings.php" | awk '{print $1}')"
  if [ "$BEFORE" = "$AFTER" ]; then
    pass "exits 0 and leaves the file byte-identical"
  else
    fail "the file changed even though the URL already matched"
  fi
else
  fail "exited non-zero when the URL already matched"
fi

echo
echo "=== refusals ==="
APP3="$(make_app three)"
if run "$APP3" "not-a-url"; then
  fail "accepted a URL without a scheme"
else
  pass "rejects a URL without a scheme"
fi

if run "$TMP/does-not-exist" "$NEW"; then
  fail "accepted an app root with no settings file"
else
  pass "refuses when there is no settings file to rebase"
fi

APP4="$(make_app four)"
printf '<?php\ndefine("CIVICRM_UF", "Standalone");\n' > "$APP4/private/civicrm.settings.php"
if run "$APP4" "$NEW"; then
  fail "accepted a settings file that does not define CIVICRM_UF_BASEURL"
else
  pass "refuses a settings file with no base URL to rebase"
fi

echo
echo "=== no argument: fall back to the environment URL ==="
# The platform passes ${env.url} in CIVICRM_ENV_URL. It must NOT be expanded as
# ${env.url} in bash: a parameter name cannot contain '.', and that is a fatal
# "bad substitution" - the bug that killed a fresh import.
APP5="$(make_app five)"
if run_env "$APP5" CIVICRM_ENV_URL=https://env.example.org; then
  GOT5="$(php -r 'require $argv[1]; echo CIVICRM_UF_BASEURL;' "$APP5/private/civicrm.settings.php" 2>/dev/null)"
  [ "$GOT5" = "https://env.example.org" ] \
    && pass "uses CIVICRM_ENV_URL when no argument is given" \
    || fail "used '${GOT5}', expected https://env.example.org"
else
  sed 's/^/  | /' "$TMP/out" | tail -8
  fail "exited non-zero when only CIVICRM_ENV_URL was set"
fi

echo
echo "=== no argument and no URL at all ==="
APP6="$(make_app six)"
if run "$APP6"; then
  fail "accepted a run with no URL to move to"
else
  if grep -qi 'bad substitution' "$TMP/out"; then
    fail "died with 'bad substitution' instead of a usage message"
  else
    pass "refuses with a usage message, not a bash error"
  fi
fi

echo
[ "$FAIL" -eq 0 ] && echo "  set-base-url test PASSED" || echo "  set-base-url test FAILED"
exit "$FAIL"
