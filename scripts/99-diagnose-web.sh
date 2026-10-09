#!/usr/bin/env bash
# 99-diagnose-web.sh - run ON THE PHP CONTAINER.
#
# Read-only. Works out what is actually serving the site, because the answer so
# far has been assumed rather than measured:
#
#   * the JPS asked for nodeType `apache`, yet /etc/httpd and /etc/apache2 do not
#     both exist, which means the template may be fronted by NGINX or LiteSpeed
#   * that matters a lot: NGINX ignores .htaccess entirely, so every protection
#     this box relies on (private/ deny-all, mod_php ini settings) would be
#     silently inert
#
# Everything here only reads. Paste the whole output back.
set -uo pipefail

sec() { printf '\n=== %s ===\n' "$*"; }

sec "1. who is listening"
if command -v ss >/dev/null 2>&1; then
  ss -lntp 2>/dev/null | head -20
elif command -v netstat >/dev/null 2>&1; then
  netstat -lntp 2>/dev/null | head -20
else
  echo "(no ss/netstat)"
  cat /proc/net/tcp 2>/dev/null | awk 'NR>1{print $2, $4}' | head -20
fi

sec "2. web server processes"
ps -eo pid,user,comm,args 2>/dev/null \
  | grep -iE 'httpd|apache2|nginx|lsws|litespeed|php-fpm|php-fpm' \
  | grep -v grep | cut -c1-200 | head -25
if ! ps -eo comm 2>/dev/null | grep -qiE 'httpd|apache2|nginx|lsws'; then
  echo "(no web server process visible - it may not be running yet)"
fi

sec "3. which binaries exist"
for b in httpd apache2 apachectl nginx lsws caddy php-fpm; do
  p="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$p" ] && printf '  %-10s %s\n' "$b" "$p"
done

sec "4. versions and compiled-in config paths"
for b in httpd apache2 nginx lsws; do
  command -v "$b" >/dev/null 2>&1 || continue
  echo "--- $b"
  case "$b" in
    httpd|apache2) "$b" -v 2>&1 | head -2 | sed 's/^/    /'
                   "$b" -V 2>&1 | grep -i 'SERVER_CONFIG_FILE_PATH\|HTTPD_ROOT' | sed 's/^/    /' ;;
    nginx)         "$b" -v 2>&1 | head -2 | sed 's/^/    /'
                   "$b" -V 2>&1 | tr ' ' '\n' | grep -iE 'prefix|conf-path' | sed 's/^/    /' ;;
    lsws)          "$b" -v 2>&1 | head -3 | sed 's/^/    /' ;;
  esac
done

sec "5. candidate config directories that actually exist"
for d in /etc/httpd /etc/httpd/conf.d /etc/apache2 /usr/local/apache2/conf \
         /etc/nginx /usr/local/nginx/conf /usr/local/lsws/conf/vhosts \
         /opt/lsws/lsphp; do
  [ -e "$d" ] && echo "  EXISTS  $d"
done
echo "  (anything not listed above does not exist)"

sec "6. auth directives anywhere in those configs"
FOUND=0
for d in /etc/httpd /usr/local/apache2/conf /etc/apache2 /etc/nginx /usr/local/nginx/conf \
         /usr/local/lsws/conf /opt/lsws; do
  [ -d "$d" ] || continue
  hits="$(grep -rniE 'auth_basic|AuthType|Require valid-user|auth_basic_user_file' "$d" 2>/dev/null | head -15)"
  if [ -n "$hits" ]; then
    echo "--- $d"
    printf '%s\n' "$hits" | sed 's/^/    /'
    FOUND=1
  fi
done
[ "$FOUND" -eq 0 ] && echo "  (no auth directives found in any config directory)"

sec "7. htpasswd files on the box"
find /etc /usr/local /var/www "$HOME" -maxdepth 4 -name '*.htpasswd' -o -maxdepth 4 -name '.htpasswd' 2>/dev/null | head -10
echo "  (empty means no password file was found either)"

sec "8. PHP SAPI and the web-facing document root"
php -r 'echo "  PHP_SAPI     : ", PHP_SAPI, PHP_EOL;
        echo "  PHP version  : ", PHP_VERSION, PHP_EOL;
        echo "  extension_dir: ", ini_get("extension_dir"), PHP_EOL;
        echo "  loaded ini   : ", php_ini_loaded_file() ?: "(none)", PHP_EOL;' 2>&1
echo
echo "  app root candidates:"
for d in "$HOME/apps/civicrm" "$HOME/httpdocs" /var/www/html /var/www/vhosts; do
  [ -d "$d" ] && echo "    EXISTS  $d"
done

sec "9. is .htaccess even honoured? (nginx never is)"
APP_ROOT="${CIVICRM_APP_DIR:-${HOME}/apps/civicrm}"
if [ -d "$APP_ROOT" ]; then
  find "$APP_ROOT" -maxdepth 2 -name '.htaccess' 2>/dev/null | sed 's/^/    /'
else
  echo "  (app root ${APP_ROOT} does not exist yet)"
fi

sec "10. what the site returns right now"
URL="${CIVICRM_SITE_URL:-}"
if [ -n "$URL" ]; then
  echo "--- headers for ${URL}/"
  curl -skI --max-time 20 "${URL}/" 2>&1 | head -15 | sed 's/^/    /'
  echo "--- body snippet (first 300 bytes, in case it is an error page)"
  curl -sk --max-time 20 "${URL}/" 2>&1 | head -c 300 | sed 's/^/    /'
  echo
else
  echo "  CIVICRM_SITE_URL is not set on this node; skipping"
fi

sec "11. intl, for reference"
php -m 2>&1 | grep -i '^intl$' | sed 's/^/    /' || true
php -m 2>&1 | grep -qi '^intl$' && echo "    intl IS loaded" || echo "    intl is NOT loaded"

printf '\n=== end: paste everything above ===\n'