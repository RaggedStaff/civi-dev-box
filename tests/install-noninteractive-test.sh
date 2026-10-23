#!/usr/bin/env bash
# install-noninteractive-test.sh - cv core:install must never be left asking a
# question nobody can answer.
#
# The failure this guards
# -----------------------
# cv core:install PROMPTS when a settings file already exists:
#
#     Found existing civicrm.settings.php in /var/www/html/private
#     The civicrm.settings.php already exists. What would you like to do?
#       [a] Abort. (Default.) (Equivalent to -A.)
#       [k] Keep existing civicrm.settings.php.
#       [o] Overwrite with new civicrm.settings.php.
#      >
#     [Exception]  Aborted
#
# With no TTY the prompt receives nothing, the default is Abort, and the install
# dies with exit 1. It happens precisely when this script has decided the site is
# NOT installed - so it runs the installer - while a settings file from an
# earlier or partial attempt is still on disk. Two decisions disagree and the
# script hangs on a question no one can answer.
#
# So the script must answer explicitly with -f whenever a settings file is
# present, and must not pass it when there is nothing to overwrite.
#
# Method: run the REAL 30-install-civicrm.sh against a stub lib.sh and a stub cv
# that records its argv. Asserting on the script's text would only prove the
# string "-f" is somewhere in the file; asserting on what cv was actually handed
# proves the decision, including that it is conditional on the file's existence.
set -uo pipefail

BOX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
TMP="$(mktemp -d)"

pass() { printf '  [ ok ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# --- Stub cv: record argv, and behave like the real one ----------------------
# It must also CREATE the settings file, because 30-install-civicrm.sh verifies
# afterwards that one exists - without that the script dies at the verification
# step and every assertion below fails for an unrelated reason.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/cv" <<'STUB'
#!/usr/bin/env bash
# APP is passed in through the environment by run_case. APP_ROOT cannot be used:
# 30-install-civicrm.sh assigns it as a plain shell variable, so a child process
# never sees it.
ROOT="${APP:-}"
if [ "${1:-}" = "--version" ]; then
  echo "cv 0.0.0-test"
  exit 0
fi
[ -n "${ARGV_OUT:-}" ] && printf '%s\n' "$@" > "$ARGV_OUT"

# Reproduce the real failure: an existing settings file without -f is a prompt,
# and a prompt with no TTY is Abort.
if [ -f "$ROOT/private/civicrm.settings.php" ]; then
  saw_f=0
  for a in "$@"; do [ "$a" = "-f" ] && saw_f=1; done
  if [ "$saw_f" -eq 0 ]; then
    echo "The civicrm.settings.php already exists. What would you like to do?" >&2
    echo "  [a] Abort. (Default.)" >&2
    echo " > " >&2
    echo "[Exception] Aborted" >&2
    exit 1
  fi
fi
mkdir -p "$ROOT/private"
printf '<?php $civicrm_setting["dsn"]="stub";' > "$ROOT/private/civicrm.settings.php"
exit 0
STUB
chmod +x "$TMP/bin/cv"

# --- Stub lib.sh: the REAL one, with only the environment-dependent parts ---
# Starting from the real file rather than reimplementing it: 30-install-civicrm.sh
# relies on lib.sh's `: "${CIVICRM_DB_PORT:=3306}"`-style defaults, and a stub
# missing one of them fails on `set -u` before reaching the code under test.
# Appending overrides works because later definitions win as the file is sourced.
cp "$BOX/scripts/lib.sh" "$TMP/lib.sh"
cat >> "$TMP/lib.sh" <<STUB

# --- overrides for this test ---
detect_app_root() { printf '%s' "\$APP"; }
resolve_db_host() { printf '127.0.0.1'; }
wait_for_db()     { :; }
generate_site_key(){ printf 'testsitekey'; }
ensure_cv()       { printf %s $TMP/bin/cv; }
civicrm_installed() { return 1; }

# This test is about the -f decision, not about permissions. The real
# settings_visible_to_web() would ask www-data to stat a file under mktemp's
# 0700 directory and correctly say no, and the real ensure_data_dirs() would
# chown /var/lib/civicrm-data on the HOST. Neither belongs here;
# data-dirs-test.sh exercises visibility in a real container with www-data.
settings_visible_to_web() { return 0; }
ensure_data_dirs()        { :; }
STUB

cp "$BOX/scripts/30-install-civicrm.sh" "$TMP/30.sh"

run_case() {
  # $1 = case name, $2 = create settings file? (yes/no), $3 = where the URL comes from
  local with_settings="$2" url_src="${3:-site-url}"
  local app="$TMP/app-$1"
  rm -rf "$app"; mkdir -p "$app/private" "$app/core"
  printf '<?php echo 1;' > "$app/civicrm.standalone.php"
  if [ "$with_settings" = "yes" ]; then
    printf '<?php $civicrm_setting["dsn"]="stale";' > "$app/private/civicrm.settings.php"
  fi

  local -a vars=(
    "APP=$app"
    "ARGV_OUT=$TMP/argv-$1"
    "CIVICRM_DB_PASS=testpass"
    "CIVICRM_ADMIN_PASS=testadmin"
  )
  case "$url_src" in
    site-url) vars+=( "CIVICRM_SITE_URL=https://example.org" ) ;;
    env-url)  vars+=( "CIVICRM_ENV_URL=https://env.example.org" ) ;;
    none)     ;;
  esac

  # Clear anything inherited from the caller so each case really tests what it
  # says it does.
  env -u CIVICRM_SITE_URL -u CIVICRM_ENV_URL "${vars[@]}" \
    bash "$TMP/30.sh" >"$TMP/out-$1" 2>&1
}

echo "=== case A: a settings file IS present ==="
if run_case with yes 2>"$TMP/err"; then
  pass "the script exits 0 (it did not hang and was not Aborted)"
else
  sed 's/^/  | /' "$TMP/out-with" | tail -12
  fail "the script exited non-zero"
fi

if grep -qx -- '-f' "$TMP/argv-with"; then
  pass "cv was given -f, so it does not prompt"
else
  fail "cv was NOT given -f; it will prompt and Abort"
fi

if [ -f "$TMP/app-with/private/civicrm.settings.php.preinstall.bak" ]; then
  pass "the previous settings file was kept as .preinstall.bak"
else
  fail "the previous settings file was not backed up before overwriting"
fi

echo
echo "=== case B: no settings file (a genuine first install) ==="
if run_case fresh no 2>"$TMP/err2"; then
  pass "the script exits 0"
else
  sed 's/^/  | /' "$TMP/out-fresh" | tail -12
  fail "the script exited non-zero"
fi

if grep -qx -- '-f' "$TMP/argv-fresh"; then
  fail "-f was passed with nothing to overwrite (forces an overwrite on a clean box)"
else
  pass "cv was NOT given -f (nothing to overwrite on a clean install)"
fi

# cv must still have been invoked as an install at all - otherwise case B is a
# pass because nothing ran.
if grep -qx 'core:install' "$TMP/argv-fresh"; then
  pass "cv core:install was actually invoked"
else
  fail "cv core:install was not invoked - the other assertions prove nothing"
fi

echo
echo "=== case C: site-url setting blank, the environment URL is supplied ==="
# This is the exact shape of a fresh platform import: the operator leaves the
# optional site-url setting empty, so the manifest passes ${env.url} in a
# separate variable. The install used to die here with
#
#     line 74: ${env.url}: bad substitution
#
# because ${env.url} is JPS syntax and bash rejects a parameter name containing
# '.'. It stayed hidden while CIVICRM_SITE_URL was always non-empty, since bash
# expands the fallback of ${a:-${b}} lazily.
if run_case envurl no env-url 2>"$TMP/err3"; then
  pass "the script exits 0"
else
  sed 's/^/  | /' "$TMP/out-envurl" | tail -12
  fail "the script exited non-zero"
fi

if grep -qi 'bad substitution' "$TMP/out-envurl"; then
  fail "died with 'bad substitution' - JPS syntax reached bash"
else
  pass "no bash 'bad substitution'"
fi

if grep -qx -- '--cms-base-url=https://env.example.org' "$TMP/argv-envurl"; then
  pass "cv was given the environment URL as the base URL"
else
  fail "cv did not receive --cms-base-url=https://env.example.org (argv: $(tr '\n' ' ' < "$TMP/argv-envurl" 2>/dev/null))"
fi

echo
[ "$FAIL" -eq 0 ] && echo "  install-noninteractive test PASSED" || echo "  install-noninteractive test FAILED"
exit "$FAIL"
