#!/usr/bin/env bash
# Exercise wait_for_db against a real MariaDB, for each outcome.
set -uo pipefail
BOX=/home/raggedstaff/gitrepos/Food-Data-Collaboration/civi-dev-box
PORT=13399

cleanup() { docker rm -f civicrm-db-test >/dev/null 2>&1 || true; }
cleanup

probe() { # $1 label, $2 user, $3 pass, $4 db, $5 port
  printf '  %-30s ' "$1"
  local t0 t1
  t0=$(date +%s)
  out="$(CIVICRM_DB_HOST=127.0.0.1 CIVICRM_DB_PORT="${5:-$PORT}" \
         CIVICRM_DB_USER="$2" CIVICRM_DB_PASS="$3" CIVICRM_DB_NAME="$4" \
         bash -c ". ${BOX}/scripts/lib.sh; log(){ printf '[civi] %s\n' \"\$*\" >&2; }; wait_for_db" 2>&1)"
  local rc=$?
  t1=$(date +%s)
  printf 'exit=%s in %ss  %s\n' "$rc" "$((t1-t0))" "$(printf '%s' "$out" | head -1 | cut -c1-58)"
}

echo "=== nothing listening (port with no container) ==="
probe "connection refused" civicrm pw civicrm 19999

echo
echo "=== starting a real MariaDB with user + database ==="
docker run -d --name civicrm-db-test \
  -e MARIADB_ROOT_PASSWORD=rootpw -e MARIADB_DATABASE=civicrm \
  -e MARIADB_USER=civicrm -e MARIADB_PASSWORD=civicrmpw \
  -p "${PORT}:3306" mariadb:12.3 >/dev/null 2>&1
for i in $(seq 1 60); do
  docker exec civicrm-db-test mariadb -u civicrm -pcivicrmpw -e 'SELECT 1' civicrm >/dev/null 2>&1 && { echo "  ready after ${i}s"; break; }
  sleep 2
done

echo
echo "=== outcomes (1045/1049 must fail FAST, not after 270s) ==="
probe "correct credentials"    civicrm civicrmpw civicrm
probe "wrong password (1045)"  civicrm WRONGPW   civicrm
probe "database absent (1049)" civicrm civicrmpw nosuchdb
probe "wrong user (1045)"      nosuchuser civicrmpw civicrm

cleanup