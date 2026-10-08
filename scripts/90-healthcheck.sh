#!/usr/bin/env bash
# 90-healthcheck.sh - run ON THE PHP CONTAINER.
#
# Single command that answers "is this dev box actually healthy?". Useful as a
# smoke test in CI, or after a redeploy, before you start testing an extension.
set -euo pipefail
# shellcheck source=lib.sh
_CIVI_SELF="${BASH_SOURCE[0]:-$0}"
. "$(dirname "$_CIVI_SELF")/lib.sh" || {
  echo "civi: cannot source lib.sh (looked next to '${_CIVI_SELF}')" >&2
  echo "civi: run this script as a FILE - piping it into 'bash -s' leaves BASH_SOURCE unset." >&2
  echo "civi: JPS hooks must use: curl -fsS <url> -o \$d/NAME.sh && bash \$d/NAME.sh" >&2
  exit 1
}

FAILURES=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
info() { printf '  \033[36mINFO\033[0m  %s\n' "$*"; }

echo "=== CiviCRM dev box healthcheck ==="

# --- Runtime ---------------------------------------------------------------
echo "[runtime]"
php -r 'printf("  PHP %s (%s)\n", PHP_VERSION, PHP_SAPI);'
for ext in $CIVICRM_REQUIRED_EXTENSIONS; do
  if php -m | tr 'A-Z' 'a-z' | grep -qx "$ext"; then ok "ext $ext"; else bad "ext $ext missing"; fi
done

# --- Layout ----------------------------------------------------------------
echo "[layout]"
if APP_ROOT="$(detect_app_root 2>/dev/null)"; then
  ok "project root ${APP_ROOT}"
  [ -f "${APP_ROOT}/civicrm.standalone.php" ] && ok "boot file present" || bad "civicrm.standalone.php missing"
  for d in core public private ext; do
    [ -e "${APP_ROOT}/${d}" ] && ok "${d}/ present" || bad "${d}/ missing"
  done
  # Writable trees must resolve onto the persistent volume, not the ephemeral tree.
  for d in private public ext; do
    if [ -L "${APP_ROOT}/${d}" ]; then
      ok "${d}/ is a symlink -> $(readlink -f "${APP_ROOT}/${d}")"
    else
      bad "${d}/ is NOT symlinked to ${CIVICRM_DATA_DIR} (will be lost on redeploy)"
    fi
  done
else
  bad "no CiviCRM Standalone project root found"
fi

# --- Install ---------------------------------------------------------------
echo "[install]"
if civicrm_installed 2>/dev/null; then
  ok "private/civicrm.settings.php present"
else
  bad "CiviCRM not installed (no private/civicrm.settings.php)"
fi

# --- Database --------------------------------------------------------------
echo "[database]"
DB_HOST="$(resolve_db_host || true)"
if [ -z "$DB_HOST" ]; then
  bad "cannot resolve database host"
else
  info "host ${DB_HOST}:${CIVICRM_DB_PORT}"
  if php -r '
      try {
        $pdo = new PDO(sprintf("mysql:host=%s;port=%d;dbname=%s",
          getenv("H"), (int)getenv("P"), getenv("D")), getenv("U"), getenv("W"),
          [PDO::ATTR_TIMEOUT => 5]);
        echo "  server ".$pdo->query("SELECT VERSION()")->fetchColumn()."\n";
        echo "  sql_mode ".$pdo->query("SELECT @@sql_mode")->fetchColumn()."\n";
        $t = $pdo->query("SHOW TABLES LIKE \"civicrm_%\"")->fetchAll();
        echo "  civicrm tables ".(count($t) ? count($t) : 0)."\n";
        exit(0);
      } catch (Throwable $e) { fwrite(STDERR, "  error ".$e->getMessage()."\n"); exit(1); }
    ' H="$DB_HOST" P="$CIVICRM_DB_PORT" D="${CIVICRM_DB_NAME:-civicrm}" \
      U="${CIVICRM_DB_USER:-civicrm}" W="${CIVICRM_DB_PASS:-}"; then
    ok "database reachable"
  else
    bad "database connection failed"
  fi
fi

# --- Extension -------------------------------------------------------------
if [ -n "${CIVICRM_EXT_KEY:-}" ]; then
  echo "[extension ${CIVICRM_EXT_KEY}]"
  if [ -d "$(data_ext)/${CIVICRM_EXT_KEY}" ] || [ -L "$(data_ext)/${CIVICRM_EXT_KEY}" ]; then
    ok "present in ext-dir"
  else
    bad "not found in $(data_ext)"
  fi
fi

# --- Cron ------------------------------------------------------------------
echo "[cron]"
CRONTAB="$(crontab -l 2>/dev/null || true)"
if printf '%s' "$CRONTAB" | grep -q 'civicrm'; then
  ok "civicrm cron entries present"
else
  bad "no civicrm cron entries - scheduled jobs will not run"
  printf '        suggested: * * * * * cd %s && %s -f -n civicrm -l en_US %s core:job --user=1\n' \
    "$(detect_app_root 2>/dev/null || echo /var/www/app)" \
    "$(command -v cv || echo "${HOME}/bin/cv")" \
    "$(detect_app_root 2>/dev/null || echo /var/www/app)"
fi

echo "=== $( [ "$FAILURES" -eq 0 ] && echo 'ALL CHECKS PASSED' || echo "${FAILURES} CHECK(S) FAILED" ) ==="
exit $(( FAILURES > 0 ? 1 : 0 ))
