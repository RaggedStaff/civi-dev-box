#!/usr/bin/env bash
# 96-why-routing.sh - why does /civicrm/login 404 while / works?
#
# The fault this looks for
# -----------------------
# CiviCRM Standalone is a front-controller app. The release's .htaccess ends
# with:
#
#     RewriteCond %{REQUEST_FILENAME} !-f
#     RewriteCond %{REQUEST_FILENAME} !-d
#     RewriteCond %{REQUEST_URI} !=/favicon.ico
#     RewriteRule ^ index.php [L]
#
# Remove that and Apache serves only what exists as a file on disk. So the site
# appears half-broken in a very specific shape:
#
#     /                         200   index.php, a real file
#     /civicrm.standalone.php   200   also a real file
#     /civicrm/login            404   not a file - it only exists as a rewrite
#
# That shape is easy to mistake for a failed install, because the install DID
# succeed and /civicrm/login is where you would go to see it. Every health check
# in this repo - 15-start-web.sh and 90-healthcheck.sh both - probes
# civicrm.standalone.php or index.php, i.e. exactly the two URLs that keep
# working. None of them could have caught this.
#
# This is the first check that deliberately probes a URL which is not a file.
#
# Two ways to get here, with the same outward symptom:
#   1. the .htaccess rewrite rules were destroyed (20-fetch-civicrm.sh did this)
#   2. Apache cannot READ the .htaccess - AllowOverride plus an unreadable file
#      is 403 for every request in the directory, permissions never mentioned.
#   (A third: mod_rewrite not loaded, or AllowOverride too low to honour it.)
#
# Run on the PHP node:  bash 96-why-routing.sh
set -uo pipefail

# shellcheck source=lib.sh
_CIVI_SELF="${BASH_SOURCE[0]:-$0}"
. "$(dirname "$_CIVI_SELF")/lib.sh" || {
  echo "civi: cannot source lib.sh (looked next to '${_CIVI_SELF}')" >&2
  exit 1
}

log "=== why routing ==="

# --- Port --------------------------------------------------------------------
PORT=""
for _ in $(seq 1 10); do
  PORT="$(listening_ports | awk '$1 == 80 || $1 == 8080 || $1 == 8000 { print $1; exit }')"
  [ -n "$PORT" ] && break
  sleep 1
done
if [ -z "$PORT" ]; then
  die "nothing is listening on 80, 8080 or 8000.
  Ports actually open: $(listening_ports | tr '\n' ' ')
  (Only 22 means SSH is up and the web server never started - which is what the
  platform does, because its container agent is PID 1 and our image's CMD never
  runs. A suspended environment that is started again is the usual trigger:
  that fires onAfterStartNode, not onAfterRestartNode.)

  This is not a routing problem, so restoring .htaccess would not help.
  Repair it:      make start-web TARGET=<node>     (runs 15-start-web.sh)
  If that does not bring it up, diagnose: make why-502 TARGET=<node>"
fi
log "listening on port ${PORT}"

# --- The decisive comparison -------------------------------------------------
# Ask for one URL that IS a file and one that is NOT. The difference between
# them is the whole diagnosis; either one alone proves nothing.
FILE_URL="/civicrm.standalone.php"
[ -f "$(detect_document_root)/${FILE_URL#/}" ] || FILE_URL="/index.php"

CODE_FILE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
             "http://127.0.0.1:${PORT}${FILE_URL}" 2>/dev/null)"
CODE_ROUTE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
              "http://127.0.0.1:${PORT}/civicrm/login" 2>/dev/null)"

log "${FILE_URL}  -> ${CODE_FILE:-no response}   (a real file - needs no routing)"
log "/civicrm/login -> ${CODE_ROUTE:-no response}   (not a file - needs the rewrite)"

# --- Report ------------------------------------------------------------------
ROUTING_OK=0
case "$CODE_ROUTE" in
  200|301|302|303|307|308)
    ok=1
    ;;
  *)
    ROUTING_OK=1
    ok=0
    ;;
esac

if [ "$ok" = "1" ]; then
  log "rewrite routing is working"
else
  warn "/civicrm/login returned ${CODE_ROUTE:-no response} while ${FILE_URL} returned ${CODE_FILE:-no response}."
  warn "That difference is the diagnosis: Apache is serving real files and not"
  warn "rewriting anything else."
fi

# --- Why? Check each cause rather than naming one ----------------------------
DOCROOT="$(detect_document_root)"
HTA="${DOCROOT}/.htaccess"
log ""
log "document root: ${DOCROOT}"

if [ ! -f "$HTA" ]; then
  warn "${HTA} does not exist at all."
  warn "  fix: make restore-htaccess TARGET=<node>   (re-fetches it from the release)"
  ROUTING_OK=1
else
  MODE="$(stat -L -c '%a' "$HTA" 2>/dev/null || echo '?')"
  log ".htaccess mode: ${MODE}"

  # Apache reads this as www-data. Note the bitmask for 'other': r=4 w=2 x=1,
  # so readable is 4..7 - NOT "an odd digit", which is the easy mistake here.
  case "$MODE" in
    *[4567]) log "  Apache can read it" ;;
    *)
      warn "Apache CANNOT read ${HTA} (mode ${MODE})."
      warn "With AllowOverride set, an unreadable .htaccess makes Apache return"
      warn "403 for EVERY request in this directory - and never mentions the file."
      warn "  fix: chmod 644 ${HTA}"
      ROUTING_OK=1
      ;;
  esac

  if grep -qiE '^[[:space:]]*RewriteRule' "$HTA"; then
    log "rewrite rules present ($(grep -ciE '^[[:space:]]*RewriteRule' "$HTA") of them)"
    # The one that does the routing, specifically. Another rule existing proves
    # nothing about whether the front-controller rule survived.
    if grep -qE '^[[:space:]]*RewriteRule[[:space:]]+\^[[:space:]]+index\.php' "$HTA"; then
      log "  the front-controller rule (RewriteRule ^ index.php) is present"
    else
      warn "rewrite rules exist but the front-controller rule is MISSING."
      warn "  Expected: RewriteRule ^ index.php [L]"
      warn "  This .htaccess is not the one the release shipped."
      warn "  fix: make restore-htaccess TARGET=<node>"
      ROUTING_OK=1
    fi
  else
    warn "${HTA} contains no RewriteRule."
    warn "This is the cause. CiviCRM Standalone routes every URL that is not a"
    warn "real file through index.php; without that rule /civicrm/login cannot"
    warn "be reached, while / and civicrm.standalone.php keep returning 200."
    warn "  fix: make restore-htaccess TARGET=<node>"
    ROUTING_OK=1
  fi
fi

# mod_rewrite has to be loaded, and Apache has to be configured to honour
# .htaccess at all. Both fail the same way - Apache simply does not rewrite -
# and neither is visible from the file itself.
#
# AllowOverride is checked in conf-enabled as well as sites-enabled: this image
# ships `AllowOverride All` in /etc/apache2/conf-enabled/docker-php.conf, so a
# search limited to sites-enabled finds nothing and reports a problem on a box
# that is perfectly healthy.
log ""
if command -v apache2ctl >/dev/null 2>&1 && [ -r /etc/apache2/envvars ]; then
  # shellcheck disable=SC1091
  . /etc/apache2/envvars
fi
if command -v apache2ctl >/dev/null 2>&1; then
  if apache2ctl -M 2>/dev/null | grep -q 'rewrite_module'; then
    log "mod_rewrite is loaded"
  else
    warn "mod_rewrite is NOT loaded - .htaccess rewrite rules are inert."
    warn "  fix: a2enmod rewrite, then restart Apache (this image has it on)"
    ROUTING_OK=1
  fi
else
  warn "apache2ctl not found - could not check mod_rewrite"
fi

AO_LINE=""
for f in /etc/apache2/conf-enabled/*.conf /etc/apache2/sites-enabled/*.conf; do
  [ -r "$f" ] || continue
  hit="$(grep -E '^[[:space:]]*AllowOverride[[:space:]]+All' "$f" 2>/dev/null | head -1)"
  if [ -n "$hit" ]; then
    AO_LINE="${f}:$(printf '%s' "$hit" | tr -s ' ')"
    break
  fi
done

if [ -n "$AO_LINE" ]; then
  log "AllowOverride honoured:${AO_LINE}"
else
  AO_NONE="$(grep -rEhs '^[[:space:]]*AllowOverride[[:space:]]+None' \
             /etc/apache2/conf-enabled /etc/apache2/sites-enabled 2>/dev/null | head -1)"
  if [ -n "$AO_NONE" ]; then
    warn "no AllowOverride All anywhere, only: ${AO_NONE}"
    warn ".htaccess would be IGNORED, so no rewrite can happen."
    warn "  fix: AllowOverride All for the vhost covering ${DOCROOT}"
    ROUTING_OK=1
  else
    warn "could not determine AllowOverride - check /etc/apache2 by hand."
    warn "Not failing on this alone: the rewrite request above already measured"
    warn "the result, which is what actually matters."
  fi
fi

echo
if [ "$ROUTING_OK" -eq 0 ]; then
  log "=== routing is healthy ==="
  log "If the page is still wrong, the fault is elsewhere - try:"
  log "  make why-installer TARGET=<node>   (installed but showing the installer?)"
  log "  make why-502    TARGET=<node>      (nothing serving at all?)"
else
  die "routing is broken - see the warnings above for the cause and the fix.
  The one-line repair is:  make restore-htaccess TARGET=<node>"
fi
