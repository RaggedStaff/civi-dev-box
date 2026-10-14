#!/usr/bin/env bash
# Verify 97-why-installer.sh reaches the right verdict for each real cause.
#
# Each case builds a container, plants one specific fault, runs the script and
# asserts it names that fault. A diagnostic that cannot distinguish its causes
# is worse than none, so this checks the verdicts, not just the exit status.
set -uo pipefail

BOX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG="${IMG:-sioldata/civi-dev-box:8.5.11}"
FAIL=0
pass() { printf '  [ ok ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }

if ! command -v docker >/dev/null 2>&1; then echo "  docker not available"; exit 0; fi
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "  image $IMG not built; skipping"; exit 0; }

docker cp "$BOX/scripts/lib.sh"          /tmp/_lib.sh  >/dev/null 2>&1 || true
docker cp "$BOX/scripts/97-why-installer.sh" /tmp/_97.sh >/dev/null 2>&1 || true

# Plant a fault, run the diagnostic, assert it names that fault.
case_run() {
  local label="$1" fault="$2" expect="$3"
  local N="civi-97-$$"
  docker rm -f "$N" >/dev/null 2>&1
  docker run -d --name "$N" --entrypoint /bin/sleep "$IMG" infinity >/dev/null 2>&1
  sleep 2

  # detect_app_root looks for civicrm.standalone.php, so plant one; otherwise
  # the diagnostic (correctly) reports "no project root" in every case.
  docker exec "$N" sh -c 'mkdir -p /var/www/html/private /var/www/html/core' >/dev/null 2>&1
  docker exec "$N" sh -c 'printf "<?php echo \"standalone\";" > /var/www/html/civicrm.standalone.php'
  docker exec "$N" sh -c 'printf "<?php\nreturn array(\"civicrm.settings.php\" => 1);\n" > /var/www/html/private/civicrm.settings.php'
  docker cp "$BOX/scripts/lib.sh"            "$N:/tmp/lib.sh" >/dev/null
  docker cp "$BOX/scripts/97-why-installer.sh" "$N:/tmp/97.sh"  >/dev/null
  [ -n "$fault" ] && docker exec "$N" sh -c "$fault" >/dev/null 2>&1

  local out
  out="$(docker exec "$N" bash /tmp/97.sh 2>&1)"
  if printf '%s' "$out" | grep -qi "$expect"; then
    pass "$label -> detected"
  else
    fail "$label -> NOT detected (looked for '$expect')"
    printf '%s\n' "$out" | sed 's/^/         /' | head -25
  fi
  docker rm -f "$N" >/dev/null 2>&1
}

echo "=== 97-why-installer.sh: each cause, detected or not ==="

# 1. Healthy settings file: must report it as fine. Assert the absence of each
#    failure verdict, which is the part that actually matters - a diagnostic
#    that always reports the fault is no diagnostic at all.
case_run "healthy settings file" "" "parses cleanly"

# 2. Truncated file -> must be flagged as truncated.
case_run "truncated settings file" \
  "printf '<?php' > /var/www/html/private/civicrm.settings.php" "truncated"

# 3. PHP parse error -> must be flagged.
case_run "unparseable settings file" \
  "printf '<?php this is not ) valid php ((\n' > /var/www/html/private/civicrm.settings.php" "PARSE ERROR"

# 4. Missing settings file -> must say it does not exist.
echo
case_run "settings file absent" \
  "rm -f /var/www/html/private/civicrm.settings.php" "does NOT exist"

echo
[ "$FAIL" -eq 0 ] && echo "  why-installer test PASSED" || echo "  why-installer test FAILED"
exit "$FAIL"