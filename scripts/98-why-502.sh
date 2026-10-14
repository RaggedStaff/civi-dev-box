#!/usr/bin/env bash
# 98-why-502.sh - run ON THE PHP CONTAINER.
#
# A 502 from the platform's frontend means nginx is answering but the upstream
# is not. That is a statement about THIS container, so this script answers the
# only two questions that matter:
#
#   1. Is anything listening on an HTTP port?
#   2. If something is listening, does it actually serve our document root?
#
# Everything else (the certificate, the custom domain, the dashboard) is
# downstream of those two answers, and diagnosing in the other order wastes a
# lot of time: a 502 on a custom domain looks identical whether the domain is
# wrong, SSL is unprovisioned, or the app was never running.
#
# Read-only. Paste the whole output back.
set -uo pipefail

# This script is deliberately standalone: it is the one thing you run when
# nothing else works, so it must not depend on lib.sh being present next to it.
# listening_ports() is duplicated from lib.sh rather than sourced - see the
# comment there for why it reads /proc/net/tcp instead of calling ss.
listening_ports() {
  local f hex
  {
    for f in /proc/net/tcp /proc/net/tcp6; do
      [ -r "$f" ] || continue
      awk 'NR > 1 && $4 == "0A" { split($2, a, ":"); print a[2] }' "$f" 2>/dev/null
    done
  } | while read -r hex; do
      printf '%d\n' "$((16#${hex}))" 2>/dev/null
    done | sort -un
}

sec() { printf '\n=== %s ===\n' "$*"; }
ok()  { printf '  [ ok ] %s\n' "$*"; }
bad() { printf '  [BAD ] %s\n' "$*"; }
info(){ printf '  [info] %s\n' "$*"; }

# --- 1. Is a web server process alive? ---------------------------------------
sec "1. web server process"
WEBPROC=""
for p in apache2 httpd nginx php-fpm; do
  if pgrep -x "$p" >/dev/null 2>&1; then
    WEBPROC="$p"
    ok "$p is running (pid $(pgrep -x "$p" | tr '\n' ' '))"
  fi
done
[ -n "$WEBPROC" ] || bad "NO web server process is running - nothing can answer, hence 502"

# --- 2. What is listening? ---------------------------------------------------
sec "2. listening TCP ports"
# From /proc/net/tcp, NOT `ss`. On this platform `ss -lnt` returns nothing
# inside the container even when Apache is listening, so a diagnostic built on
# ss reports "nothing is listening" for a healthy server. This function reads
# the kernel's own socket table; it cannot fail that way.
LISTEN="$(listening_ports | tr '\n' ' ')"

if [ -n "$LISTEN" ]; then
  while read -r p; do
    case "$p" in
      80|8080|8000|443) ok "port $p is LISTENING" ;;
      22)               info "port $p is LISTENING (ssh)" ;;
      *)                info "port $p is LISTENING" ;;
    esac
  done <<< "$LISTEN"
else
  bad "no listening TCP ports found - the app is not serving on any port"
fi

# --- 3. Which port does Apache itself think it is on? -------------------------
sec "3. Apache's own idea of its vhost"
# Debian's apache2.conf interpolates ${APACHE_RUN_DIR} and friends, so without
# envvars the dump aborts with a syntax error that has nothing to do with us.
for b in apache2 httpd; do
  command -v "$b" >/dev/null 2>&1 || continue
  # shellcheck disable=SC1091
  [ -r /etc/apache2/envvars ] && . /etc/apache2/envvars
  "$b" -t -D DUMP_VHOSTS 2>&1 | sed 's/^/    /' | head -10
  break
done

# --- 4. Does the document root actually serve? -------------------------------
sec "4. does the document root answer?"
DOCROOT=""
for d in /var/www/html /var/www/htdocs /var/www/vhosts "$HOME/httpdocs"; do
  if [ -d "$d" ] && [ -f "$d/civicrm.standalone.php" ]; then DOCROOT="$d"; break; fi
done
[ -n "$DOCROOT" ] || DOCROOT="${CIVICRM_APP_DIR:-/var/www/html}"
info "document root: ${DOCROOT}"
[ -f "${DOCROOT}/civicrm.standalone.php" ] \
  && ok "civicrm.standalone.php is present" \
  || bad "civicrm.standalone.php is MISSING - CiviCRM is not deployed here.
    Run 'make fetch TARGET=<node>' to deploy the release code."

# A diagnostic must not be the thing that breaks. `set -u` plus an unset HOME
# killed this script one line before the answer on the real box.
if [ -z "${HOME:-}" ]; then
  warn "HOME is not set in this environment; some checks are limited"
fi

# Try every port that is listening, since we do not know which one the platform
# proxies to. Reporting "it works on 80" is not enough; we need "it works on the
# port the platform will actually ask for".
for p in $LISTEN; do
  case "$p" in 22|25|3306|5432) continue ;; esac
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${p}/" 2>/dev/null)"
  case "$code" in
    200|30[0-9]) ok "http://127.0.0.1:${p}/ returns ${code}" ;;
    403)         bad "http://127.0.0.1:${p}/ returns 403 - serving, but the docroot is denied" ;;
    000)         bad "http://127.0.0.1:${p}/ no response" ;;
    *)           bad "http://127.0.0.1:${p}/ returns ${code}" ;;
  esac
done

# --- 5. Is private/ still protected? -----------------------------------------
sec "5. credential protection"
for p in $LISTEN; do
  case "$p" in 22|25|3306|5432) continue ;; esac
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${p}/private/civicrm.settings.php" 2>/dev/null)"
  case "$code" in
    403|404) ok "private/civicrm.settings.php -> ${code} (not served)" ;;
    000)     bad "private/civicrm.settings.php -> no response" ;;
    *)       bad "private/civicrm.settings.php -> ${code}  <-- CREDENTIAL LEAK" ;;
  esac
  break
done

sec "verdict"
if [ -z "$WEBPROC" ]; then
  echo "  The web server is NOT running. That alone explains the 502."
  echo "  Restart the node from the dashboard, or re-run 'make provision'."
elif [ -z "$LISTEN" ]; then
  echo "  A web server process exists but nothing is listening."
  echo "  Check its error log: /var/log/apache2/error.log or /var/log/httpd/error_log"
else
  echo "  A web server is running and listening on: $(echo $LISTEN | tr '\n' ' ')"
  echo "  If the platform still 502s, the mismatch is the PORT: Jelastic proxies to a"
  echo "  fixed port and this container is not serving on it. Report the list above."
fi
printf '\n=== end: paste everything above ===\n'