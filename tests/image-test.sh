#!/usr/bin/env bash
# Functional test of the built image: does it serve, and does it deny private/?
set -uo pipefail
IMG=civi-dev-box:test
NAME=civitest

docker rm -f $NAME >/dev/null 2>&1 || true

echo "=== boot the image ==="
docker run --rm -d --name $NAME -p 18080:80 "$IMG" >/dev/null 2>&1
sleep 8

echo -n "  container status : "
docker inspect --format '{{.State.Status}}' "$NAME" 2>/dev/null

echo
echo "=== serving ==="
# Put a file in the docroot and a settings file in private/, as a real install would.
docker exec $NAME bash -c '
  echo "<h1>civi box</h1>" > /var/www/html/index.php
  echo "<?php \$civicrm_root=\"/var/www/html\";" > /var/www/html/private/civicrm.settings.php
' 2>/dev/null

for path in / /index.php /private/civicrm.settings.php /core/; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:18080${path}" 2>/dev/null)
  case "$path" in
    /private/*) verdict=$([ "$code" = "403" ] && echo "CORRECT (denied)" || echo "LEAK!") ;;
    *)          verdict="" ;;
  esac
  printf '  %-32s HTTP %s  %s\n' "$path" "$code" "$verdict"
done

echo
echo "=== is cron actually running (needed for cv core:job)? ==="
docker exec $NAME bash -c 'pgrep -x cron >/dev/null && echo "  cron: running" || echo "  cron: NOT RUNNING"' 2>/dev/null

echo
echo "=== apache error log, if anything is wrong ==="
docker logs $NAME 2>&1 | grep -iE 'error|warn' | head -5 | sed 's/^/  /' || echo "  clean"

docker rm -f $NAME >/dev/null 2>&1