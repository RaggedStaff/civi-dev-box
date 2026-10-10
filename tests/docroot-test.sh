#!/usr/bin/env bash
# Direct test of detect_document_root with a stub httpd, using the real lib.sh.
# All fixture paths live under $T; "@@" in the stub output expands to $T.
set -uo pipefail
LIB=/home/raggedstaff/gitrepos/Food-Data-Collaboration/civi-dev-box/scripts/lib.sh
T=/tmp/opencode/dr-direct
rm -rf "$T"; mkdir -p "$T/bin"

try() { # $1 label, $2 what the stub prints, $3 path relative to $T
  rm -rf "$T/srv" "$T/opt" "$T/var" "$T/www"
  local want="$T/$3"
  mkdir -p "$want"

  cat > "$T/bin/httpd" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
  -S) printf '%s\n' "$2" | sed "s|@@|$T|g" ;;
esac
exit 0
STUB
  chmod +x "$T/bin/httpd"

  local got
  # PATH must contain ONLY the stub. With $PATH appended, the loop tries
  # apache2 as well, finds this sandbox's real /usr/sbin/apache2, and reports
  # /var/www/html - a property of the test machine, not of the library.
  local pathdir="$T/path"
  rm -rf "$pathdir"; mkdir -p "$pathdir"
  ln -sf "$T/bin/httpd" "$pathdir/httpd"
  for b in bash sh cat sed head tr awk grep dirname mkdir rm; do
    p="$(command -v "$b")" && ln -sf "$p" "$pathdir/$b"
  done

  got="$(env -i PATH="$pathdir" HOME="$T" bash -c '. '"$LIB"'; detect_document_root' 2>&1)"
  if [ "$got" = "$want" ]; then
    printf '  %-46s PASS\n' "$1"
  else
    printf '  %-46s FAIL got=[%s]\n%50swant=[%s]\n' "$1" "$got" "" "$want"
  fi
}

echo "=== detect_document_root against realistic httpd -S output ==="
try "single vhost" \
  '                document root "@@/var/www/html"' var/www/html

try "several vhosts, first wins" \
  '                document root "@@/srv/first"
                document root "@@/srv/second"' srv/first

try "full -S preamble with other keys" \
  '*:80                   is a NameVirtualHost
        default server x:80 (INACTIVE)
        port 80 namevhost x:80 id:1 default_server
                document root "@@/opt/dr"
                load mod_ssl.c (conf path shared:/etc/httpd/modules/mod_ssl.so)' opt/dr

try "no leading indent" \
  'document root "@@/opt/tight"' opt/tight

try "unquoted value" \
  '                document root @@/var/www/plain' var/www/plain

try "path containing spaces" \
  '                document root "@@/opt/my site/html"' "opt/my site/html"
# (needs the @@ token so the stub reports a path that really exists; without it
#  the library correctly rejects the non-existent path and falls back)

try "trailing whitespace after quote" \
  '                document root "@@/var/www/tail"   ' var/www/tail

# The directive spelling must NOT be mistaken for the -S output spelling.
# /var/www/nope does not exist, so a correct implementation falls back to
# /var/www/html rather than reporting a directory that is not there.
try "DocumentRoot directive must NOT match (falls back)" \
  'DocumentRoot "@@/var/www/nope"' var/www/html