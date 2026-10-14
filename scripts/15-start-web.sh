#!/usr/bin/env bash
# 15-start-web.sh - run ON THE PHP CONTAINER.
#
# Starts Apache and cron, and proves they actually serve before returning.
#
# Why this exists
# ---------------
# The image's CMD is `civi-foreground` (cron + `exec apache2-foreground`). That
# works under plain Docker - Apache becomes PID 1 - but on this platform the
# node's CMD is replaced by the platform's own container agent, so the CMD never
# runs. The container comes up, SSH works, and Apache is simply not there:
#
#     [BAD ] NO web server process is running - nothing can answer, hence 502
#     [info] port 22 is LISTENING (ssh)
#
# while `apache2 -t` still reports a perfectly valid vhost, which is what makes
# it confusing: the configuration is fine, nothing is running it.
#
# So the web server is started from a JPS hook instead, which the platform does
# execute inside the node. Idempotent, because it also has to run after a
# restart, and verified, because "the command succeeded" is not evidence that
# anything is listening.
set -uo pipefail

# shellcheck source=lib.sh
_CIVI_SELF="${BASH_SOURCE[0]:-$0}"
. "$(dirname "$_CIVI_SELF")/lib.sh" || {
  echo "civi: cannot source lib.sh (looked next to '${_CIVI_SELF}')" >&2
  exit 1
}

log "=== start web server ==="

# Debian's apache2.conf interpolates ${APACHE_RUN_DIR} and friends; without
# these, every apache2ctl invocation dies with a DefaultRuntimeDir error.
if [ -r /etc/apache2/envvars ]; then
  # shellcheck disable=SC1091
  . /etc/apache2/envvars
fi
export APACHE_RUN_DIR="${APACHE_RUN_DIR:-/var/run/apache2}"
export APACHE_PID_FILE="${APACHE_PID_FILE:-/var/run/apache2/apache2.pid}"
export APACHE_LOCK_DIR="${APACHE_LOCK_DIR:-/var/lock/apache2}"
export APACHE_LOG_DIR="${APACHE_LOG_DIR:-/var/log/apache2}"
mkdir -p "$APACHE_RUN_DIR" "$APACHE_LOCK_DIR" "$APACHE_LOG_DIR"

APACHECTL=""
for c in apache2ctl apachectl; do
  command -v "$c" >/dev/null 2>&1 && { APACHECTL="$c"; break; }
done
[ -n "$APACHECTL" ] || die "no apache2ctl/apachectl on this node - the image is not what we think"

# --- Apache ------------------------------------------------------------------
if pgrep -x apache2 >/dev/null 2>&1 || pgrep -x httpd >/dev/null 2>&1; then
  log "apache2 already running"
else
  if "$APACHECTL" -t -D DUMP_VHOSTS >/dev/null 2>&1; then
    log "apache2 config OK, starting"
  else
    warn "apache2 config test failed:"
    "$APACHECTL" -t 2>&1 | tail -5 | sed 's/^/    /' >&2
  fi

  # -k start daemonises. If the platform's agent is PID 1 we must NOT exec, or
  # stopping Apache would take the container down.
  if ! "$APACHECTL" -k start 2>&1 | tail -5 | sed 's/^/    /' >&2; then
    die "apache2 failed to start"
  fi

  for _ in $(seq 1 15); do
    pgrep -x apache2 >/dev/null 2>&1 && break
    sleep 1
  done
fi

if pgrep -x apache2 >/dev/null 2>&1 || pgrep -x httpd >/dev/null 2>&1; then
  log "apache2 is running"
else
  # Last resort: some images ship only the foreground script.
  if command -v apache2-foreground >/dev/null 2>&1; then
    warn "apache2ctl start did not take; falling back to apache2-foreground"
    nohup apache2-foreground >/dev/null 2>&1 &
    sleep 4
  fi
fi

# --- Wait for the socket, then prove it serves --------------------------------
# listening_ports reads /proc/net/tcp, not ss - see the note in lib.sh. Trusting
# ss here reported "not listening" for an Apache that was listening.
PORT=""
for _ in $(seq 1 20); do
  PORT="$(listening_ports | awk '$1 == 80 || $1 == 8080 || $1 == 8000 { print $1; exit }')"
  [ -n "$PORT" ] && break
  sleep 1
done
[ -n "$PORT" ] || die "apache2 is not listening on 80, 8080 or 8000 after 20s.
  Ports actually open: $(listening_ports | tr '\n' ' ').
  Check its log: ${APACHE_LOG_DIR}/error.log"

log "listening on port ${PORT}"

# Probe a real file, not just "/". On a fresh container "/" returns 403 purely
# because there is no index.php yet, which is correct and says nothing about
# whether Apache is healthy. civicrm.standalone.php returning 200 is the
# signal that matters, and it is the same file CiviCRM's own entry point uses.
DOCROOT="$(detect_document_root)"
PROBE=""
for cand in "${DOCROOT}/civicrm.standalone.php" "${DOCROOT}/index.php"; do
  [ -f "$cand" ] && { PROBE="$cand"; break; }
done

if [ -n "$PROBE" ]; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://127.0.0.1:${PORT}/${PROBE##*/}" 2>/dev/null)"
  case "$CODE" in
    200) log "serving ${PROBE##*/} -> HTTP 200" ;;
    403) die "${PROBE##*/} returns 403. The file is on disk, so Apache is denying it:
    check the deny rules and the directory permissions on ${DOCROOT}." ;;
    *)   die "${PROBE##*/} returned ${CODE:-no response}" ;;
  esac
else
  warn "no civicrm.standalone.php in ${DOCROOT} yet - Apache is up, CiviCRM is not"
  warn "deployed. Run 'make fetch TARGET=<node>'."
fi

# --- cron --------------------------------------------------------------------
if pgrep -x cron >/dev/null 2>&1; then
  log "cron is running"
elif command -v cron >/dev/null 2>&1 || command -v crond >/dev/null 2>&1; then
  CROND="$(command -v cron || command -v crond)"
  "$CROND" 2>/dev/null || warn "could not start cron"
  sleep 1
  pgrep -x cron >/dev/null 2>&1 && log "cron started" || warn "cron did not start; add it via the dashboard"
else
  warn "no cron binary; add the schedule via the dashboard"
fi

log "=== web server up ==="