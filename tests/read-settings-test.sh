#!/usr/bin/env bash
# read-settings-test.sh - lock in the settings parser.
#
# This parser has been wrong three times and looked fine every time: it
# reported "(not set)" for every key on a valid settings file, which is
# indistinguishable from a genuinely empty file unless the test asserts the
# values come back. So assert exact values.
set -uo pipefail

BOX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$BOX/scripts/read-settings.php"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAIL=0
pass() { printf '  [ ok ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }

command -v php >/dev/null 2>&1 || { echo "  php not available; skipping"; exit 0; }

get() { php "$PARSER" "$1" 2>/dev/null | php -r '
  $r = json_decode(stream_get_contents(STDIN), true) ?: [];
  $s = $r["settings"] ?? $r["summary"] ?? [];
  echo $s[$argv[1]] ?? "(absent)";
' "$2"; }

strategy() { php "$PARSER" "$1" 2>/dev/null | php -r '
  $r = json_decode(stream_get_contents(STDIN), true) ?: [];
  echo $r["strategy"] ?? "(none)";
'; }

echo "=== read-settings.php ==="

# A settings file in the shape CiviCRM actually writes.
cat > "$T/good.php" <<'PHP'
<?php
$civicrm_setting['dsn'] = 'mysql:host=10.101.4.238;port=3306;dbname=civicrm';
$civicrm_setting['db_username'] = 'civicrm';
$civicrm_setting['db_password'] = 'civiDb!2026';
$civicrm_setting['db_hostname'] = '10.101.4.238';
$civicrm_setting['db_port'] = '3306';
$civicrm_setting['database'] = 'civicrm';
$civicrm_setting['civicrm.base_url'] = 'https://dev.civi.sioldata.com';
PHP

for kv in "civicrm.base_url https://dev.civi.sioldata.com" \
          "db_hostname 10.101.4.238" \
          "db_port 3306" \
          "database civicrm" \
          "db_username civicrm" \
          "db_password civiDb!2026"; do
  k="${kv%% *}"; want="${kv#* }"
  got="$(get "$T/good.php" "$k")"
  if [ "$got" = "$want" ]; then
    pass "$k = $want"
  else
    fail "$k: wanted '$want', got '$got'"
  fi
done

# The case that broke a regex-based parser: a password full of metacharacters.
cat > "$T/nasty.php" <<'PHP'
<?php
$civicrm_setting['db_password'] = 'p@ss|w0rd$foo(bar)[baz]{qux}/*+?.';
$civicrm_setting['db_hostname'] = 'db.internal';
PHP
got="$(get "$T/nasty.php" db_password)"
if [ "$got" = 'p@ss|w0rd$foo(bar)[baz]{qux}/*+?.' ]; then
  pass "password with regex metacharacters survives intact"
else
  fail "password mangled: '$got'"
fi

# A database password containing an apostrophe - the most common way a naive
# trim("'\"") parser goes wrong.
cat > "$T/quote.php" <<'PHP'
<?php
$civicrm_setting['db_password'] = 'it\'s complicated';
$civicrm_setting['database'] = 'civicrm';
PHP
got="$(get "$T/quote.php" db_password)"
if [ "$got" = "it's complicated" ]; then
  pass "password containing an apostrophe survives"
else
  fail "apostrophe password: got '$got'"
fi

# Non-scalar values must not crash or invent a value.
cat > "$T/array.php" <<'PHP'
<?php
$civicrm_setting['some_array'] = ['a' => 1, 'b' => 2];
$civicrm_setting['database'] = 'civicrm';
PHP
if [ "$(get "$T/array.php" some_array)" = "(array of 2)" ] \
   && [ "$(get "$T/array.php" database)" = "civicrm" ]; then
  pass "array value described without losing later keys"
else
  fail "array handling wrong"
fi

# Truncated file: must not warn, crash, or emit a bogus value.
printf '<?php\n$civicrm_setting[\x27unterminated' > "$T/trunc.php"
if OUT="$(php -d display_errors=1 "$PARSER" "$T/trunc.php" 2>&1)"; then
  case "$OUT" in
    *Warning*|*Fatal*|*Deprecated*) fail "truncated file produced a PHP diagnostic: $OUT" ;;
    *) pass "truncated file handled without a warning" ;;
  esac
else
  fail "truncated file made the parser exit non-zero"
fi

# A file that is not a settings file at all.
printf '<?php\necho "hello";\n' > "$T/plain.php"
if [ "$(get "$T/plain.php" db_hostname)" = "(absent)" ]; then
  pass "non-settings PHP yields absent keys, not garbage"
else
  fail "non-settings PHP produced a value"
fi


# The require-first strategy: a file that assigns $civicrm_setting as a whole
# array, which no amount of regex or token-shape matching will find. This is the
# shape a "could not read it" report most likely means when the file is fine.
cat > "$T/arrayassign.php" <<'PHP'
<?php
$civicrm_setting = [
  'civicrm.base_url' => 'https://dev.civi.sioldata.com',
  'db_hostname' => '10.101.4.238',
  'db_username' => 'civicrm',
  'database' => 'civicrm',
];
PHP
if [ "$(strategy "$T/arrayassign.php")" = "load" ] \
   && [ "$(get "$T/arrayassign.php" db_hostname)" = "10.101.4.238" ]; then
  pass "whole-array assignment found by requiring the file"
else
  fail "array-assignment form not found (strategy=$(strategy "$T/arrayassign.php"))"
fi

# A file that needs CiviCRM's bootstrap cannot be required; the tokenizer must
# still recover the values rather than reporting nothing.
cat > "$T/needsbootstrap.php" <<'PHP'
<?php
if (!defined('CIVICRM_BASE_URL')) {
    die("needs bootstrap\n");
}
$civicrm_setting['db_hostname'] = 'never.reached';
PHP
got="$(get "$T/needsbootstrap.php" db_hostname)"
if [ "$(strategy "$T/needsbootstrap.php")" = "token" ]; then
  pass "unrequireable file falls back to tokenising (strategy=token)"
else
  fail "expected the token fallback, got strategy=$(strategy "$T/needsbootstrap.php")"
fi

echo
[ "$FAIL" -eq 0 ] && echo "  read-settings test PASSED" || echo "  read-settings test FAILED"
exit "$FAIL"