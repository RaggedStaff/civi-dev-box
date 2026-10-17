#!/usr/bin/env bash
# Shared helpers for the CiviCRM dev-box scripts.
# Sourced, never executed directly.

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '[civi] %s\n' "$*" >&2; }
warn() { printf '[civi][WARN] %s\n' "$*" >&2; }
die()  { printf '[civi][FATAL] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Configuration (override via environment)
# ---------------------------------------------------------------------------
: "${CIVICRM_DATA_DIR:=/var/lib/civicrm-data}"
: "${CIVICRM_APP_DIR:=}"            # auto-detected when empty
: "${CIVICRM_VERSION:=6.18.2}"
: "${CIVICRM_DB_NAME:=civicrm}"
: "${CIVICRM_DB_USER:=civicrm}"
: "${CIVICRM_DB_PASS:=}"
: "${CIVICRM_DB_HOST:=}"
: "${CIVICRM_DB_PORT:=3306}"
: "${CIVICRM_SITE_KEY:=}"
: "${CIVICRM_DEMO_DATA:=0}"
: "${CIVICRM_ADMIN_USER:=admin}"
: "${CIVICRM_ADMIN_PASS:=}"
: "${CIVICRM_ADMIN_EMAIL:=admin@example.org}"
: "${CIVICRM_EXT_KEY:=}"
: "${CIVICRM_EXT_SOURCE:=}"          # git URL or local directory
: "${CIVICRM_EXT_BRANCH:=}"
: "${CV_BIN:=}"

# CiviCRM's documented requirements (docs.civicrm.org installation requirements)
CIVICRM_PHP_MIN="8.2"
CIVICRM_REQUIRED_EXTENSIONS="bcmath curl dom mbstring zip intl fileinfo pdo_mysql"

# :- form so a mirror set in the environment actually takes effect. A bare
# assignment here silently overwrote any override, contradicting the
# "override via environment" contract this section is under.
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://download.civicrm.org}"
CV_URL="${CV_URL:-https://download.civicrm.org/cv/cv.phar}"

# ---------------------------------------------------------------------------
# listening_ports
#
# Print every TCP port in LISTEN state, one per line, numerically sorted.
#
# Reads /proc/net/tcp rather than shelling out to ss, and that is not a
# preference. On this platform `ss -lnt` returns NOTHING inside the container
# even while Apache is demonstrably listening: /proc/net/tcp showed
# 00000000:0050 in state 0A while ss reported an empty table. A diagnostic that
# trusts ss therefore reports "nothing is listening" for a perfectly healthy
# server - and, because `ss -lnt` also exits 0 on empty output, piping it into
# a test does not even fail, it just quietly gives the wrong answer.
#
# /proc/net/tcp is the kernel's own socket table, so it cannot be wrong in the
# same way. Port 0050 hex is 80; state 0A is LISTEN.
# ---------------------------------------------------------------------------
listening_ports() {
  local f hex
  {
    for f in /proc/net/tcp /proc/net/tcp6; do
      [ -r "$f" ] || continue
      awk 'NR > 1 && $4 == "0A" { split($2, a, ":"); print a[2] }' "$f" 2>/dev/null
    done
  } | while read -r hex; do
      # shellcheck disable=SC2050
      printf '%d\n' "$((16#${hex}))" 2>/dev/null
    done | sort -un
}

# ---------------------------------------------------------------------------
# Filesystem layout
#
# The three writable trees (private/, public/, ext/) live on Jelastic volumes
# so they survive container redeploy. The app directory itself is ephemeral, so
# the release code is re-synced on every container start (see 20-fetch-civicrm.sh).
#
#   $CIVICRM_APP_DIR   ephemeral  -> civicrm.standalone.php, core/, ...
#   $CIVICRM_DATA_DIR  persistent -> private/, public/, ext/
#
# The app tree symlinks its writable directories onto the persistent ones.
# ---------------------------------------------------------------------------
data_private() { printf '%s/private'  "$CIVICRM_DATA_DIR"; }
data_public()  { printf '%s/public'   "$CIVICRM_DATA_DIR"; }
data_ext()     { printf '%s/ext'      "$CIVICRM_DATA_DIR"; }

ensure_data_dirs() {
  mkdir -p "$(data_private)" "$(data_public)" "$(data_ext)"
}

# --- Document root ----------------------------------------------------------
# CiviCRM Standalone REQUIRES the project root to BE the webserver document
# root - it explicitly does not work in a URL subdirectory. So the app root and
# the DocumentRoot have to be the same directory, and neither can be guessed:
# this platform serves /var/www/html, not $HOME/apps/civicrm, so extracting to
# $HOME/apps/civicrm produces a 500 with the app present but unserved.
#
# Ask Apache. `httpd -S` prints the parsed virtual hosts including the resolved
# DocumentRoot, which is authoritative and accounts for Include files and
# platform-generated config - all of which a hardcoded path cannot.
detect_document_root() {
  # Declare before use: every script runs under `set -u`, so referencing an
  # optional override before defaulting it aborts the script.
  local droot="${CIVICRM_DOCUMENT_ROOT:-}"
  if [ -n "$droot" ]; then
    printf '%s' "$droot"
    return 0
  fi

  local bin root found=""
  for bin in httpd apache2; do
    command -v "$bin" >/dev/null 2>&1 || continue

    # `httpd -S` prints:  document root "/path"
    #
    # Three things to get right, each of which fails SILENTLY by yielding "":
    #   * it is "document root" with a SPACE. The DocumentRoot *directive* is
    #     spelled with an underscore, and matching that finds nothing.
    #   * the value must be taken from AFTER the label, quoted-aware. $NF breaks
    #     on a path containing spaces ("/opt/my site/html" -> "site/html\""), and
    #     a plain $3 would include the opening quote.
    #   * tr -d ' "' deletes spaces too, welding the label onto the path
    #     ("document root /x" -> "documentroot/x"). Strip quotes only.
    root="$("$bin" -S 2>/dev/null \
      | sed -n 's/^[[:space:]]*document[[:space:]][[:space:]]*root[[:space:]]\{1,\}\(.*\)$/\1/p' \
      | head -1 | tr -d '"\047' | sed 's/[[:space:]]*$//')"
    if [ -n "$root" ] && [ -d "$root" ]; then
      # Keep the FIRST hit. Assigning back to `root` here would let a later
      # iteration that finds nothing reset it to empty and lose a good answer.
      found="$root"
    fi
  done
  [ -n "$found" ] && { printf '%s' "$found"; return 0; }

  # Apache absent or unhelpful: fall back to the conventional locations. Logged
  # by the caller so a guess is never silent.
  for root in /var/www/html /var/www/vhosts /var/www/domain/public_html; do
    [ -d "$root" ] && { printf '%s' "$root"; return 0; }
  done
  return 1
}

# Resolve the app root for a fresh install: the document root, because that is
# what CiviCRM needs and what the domain already points at.
resolve_target_app_dir() {
  if [ -n "$CIVICRM_APP_DIR" ]; then
    printf '%s' "$CIVICRM_APP_DIR"
    return 0
  fi
  detect_document_root
}

# Detect the CiviCRM Standalone project root by looking for the boot file.
# Used AFTER installation, when the release code is already on disk.
detect_app_root() {
  if [ -n "$CIVICRM_APP_DIR" ]; then
    [ -f "$CIVICRM_APP_DIR/civicrm.standalone.php" ] \
      || die "CIVICRM_APP_DIR=$CIVICRM_APP_DIR does not contain civicrm.standalone.php"
    printf '%s' "$CIVICRM_APP_DIR"
    return 0
  fi

  # Already installed: prefer the document root, since that is where it must be
  # and where it will have been put.
  if [ -f "${CIVICRM_DATA_DIR}/.app-dir" ]; then
    CIVICRM_APP_DIR="$(cat "${CIVICRM_DATA_DIR}/.app-dir")"
    if [ -f "$CIVICRM_APP_DIR/civicrm.standalone.php" ]; then
      printf '%s' "$CIVICRM_APP_DIR"
      return 0
    fi
  fi

  local droot
  droot="$(detect_document_root || true)"
  if [ -n "$droot" ] && [ -f "${droot}/civicrm.standalone.php" ]; then
    CIVICRM_APP_DIR="$droot"
    printf '%s' "$droot"
    return 0
  fi

  local candidate
  for candidate in \
      "$HOME"/apps/*/ \
      "$HOME"/*/ \
      /var/www/*/ \
      /var/opt/*/ \
      /var/lib/jelastic/apps/*/ ; do
    [ -f "${candidate}civicrm.standalone.php" ] || continue
    # Prefer the most specific match (apps/<name>/ over bare $HOME).
    candidate="${candidate%/}"
    if [ -z "$CIVICRM_APP_DIR" ] || [ "${#candidate}" -gt "${#CIVICRM_APP_DIR}" ]; then
      CIVICRM_APP_DIR="$candidate"
    fi
  done

  [ -n "$CIVICRM_APP_DIR" ] || die "could not locate a CiviCRM Standalone project root (civicrm.standalone.php). Set CIVICRM_APP_DIR explicitly."
  printf '%s' "$CIVICRM_APP_DIR"
}

# Point the app tree's writable directories at the persistent volumes.
link_data_dirs() {
  local app_root; app_root="$(detect_app_root)"
  ensure_data_dirs

  local pair name target
  for pair in "private:$(data_private)" "public:$(data_public)" "ext:$(data_ext)"; do
    name="${pair%%:*}"
    target="${pair#*:}"

    # Only replace a plain directory; never clobber a real symlink.
    if [ -L "${app_root}/${name}" ]; then
      :
    elif [ -d "${app_root}/${name}" ]; then
      # First run: the tarball ships empty-ish scaffolding. Merge anything
      # meaningful out of the way, then swap in the symlink.
      if [ -n "$(ls -A "${app_root}/${name}" 2>/dev/null)" ] && [ ! -e "${target}/.migrated" ]; then
        warn "migrating existing ${app_root}/${name} contents into ${target}"
        cp -a "${app_root}/${name}/." "${target}/" 2>/dev/null || true
      fi
      rm -rf "${app_root:?}/${name}"
    fi

    ln -sfn "$target" "${app_root}/${name}"
  done

  log "app root:   ${app_root}"
  log "data dir:   ${CIVICRM_DATA_DIR}"
}

# ---------------------------------------------------------------------------
# htaccess_set_block FILE BEGIN END CONTENT_FILE
#
# Set CONTENT_FILE as a delimited block inside FILE, leaving every other line
# untouched.
#
# Why this exists
# ---------------
# An .htaccess file has more than one author. CiviCRM Standalone is a
# front-controller app: /civicrm/login is not a path on disk. The release's
# .htaccess ends its rewrite block with
#
#     RewriteCond %{REQUEST_FILENAME} !-f
#     RewriteCond %{REQUEST_FILENAME} !-d
#     RewriteCond %{REQUEST_URI} !=/favicon.ico
#     RewriteRule ^ index.php [L]
#
# so the request falls through to index.php, which is the Standalone front
# controller that then routes into CiviCRM. (civicrm.standalone.php is the entry
# point it ultimately reaches, not the rewrite target - worth stating, because
# the file name suggests otherwise and the assumption is easy to make.) That
# .htaccess also carries ErrorDocument 404 /index.php, the FilesMatch deny list,
# and the cache headers. This box adds php_value directives on top.
#
# The previous version wrote the whole file to add its part:
#
#     cat > "${APP_ROOT}/.htaccess" <<HTA
#     # Managed by civi-dev-box
#     ${PHP_VALUE_BLOCK}
#     HTA
#
# which discarded the release's rewrite rules on the very first run, and on every
# run after that. The symptom was specific, and read as a broken install rather
# than as a routing fault:
#
#     /                         200   index.php, a real file, needs no rewrite
#     /civicrm.standalone.php   200   also a real file
#     /civicrm/login            404   exists ONLY as a rewrite - gone
#
# The installer had succeeded; the front controller could simply never be
# reached. Nothing in the error messages pointed at the file that caused it.
#
# So add our directives to whatever is already there, between markers, and
# replace our own block if it is already present. Idempotent, because this runs
# on every container start: a plain append would stack a duplicate block each
# time, and while a repeated php_value is harmless, a repeated RewriteRule is
# not something to rely on.
# ---------------------------------------------------------------------------
htaccess_set_block() {
  local file="$1" begin="$2" end="$3" content_file="$4"
  local tmp out mode
  tmp="$(mktemp)"  || return 1
  out="$(mktemp)"  || { rm -f "$tmp"; return 1; }

  # Capture the existing mode BEFORE overwriting. Default to 0644 for a new file.
  # This is not cosmetic: mktemp creates 0600, and an .htaccess that Apache runs
  # as www-data cannot read produces 403 Forbidden for EVERY request in the
  # directory - with no mention of permissions in the error. That is also the
  # exact symptom a lost rewrite rule produces, so getting it wrong here
  # reintroduces the same bug under a different name.
  mode="$(stat -c '%a' "$file" 2>/dev/null || printf '644')"

  if [ -f "$file" ] && grep -qF "$begin" "$file"; then
    # Replace only our previous block. sed reads the file and writes elsewhere,
    # because redirecting over the file we are reading truncates it first.
    sed "/^${begin}\$/,/^${end}\$/d" "$file" > "$tmp"
  elif [ -f "$file" ]; then
    cat "$file" > "$tmp"
  else
    : > "$tmp"
  fi

  # Collapse trailing blank lines, so replacing a longer block with a shorter
  # one cannot leave the file growing by a blank line on every start.
  awk '
    { line[NR] = $0 }
    END {
      while (NR > 0 && line[NR] ~ /^[[:space:]]*$/) NR--
      for (i = 1; i <= NR; i++) print line[i]
    }' "$tmp" > "$out"

  if [ -s "$out" ]; then
    printf '\n' >> "$out"
  fi
  printf '%s\n' "$begin"  >> "$out"
  cat "$content_file"      >> "$out"
  printf '%s\n' "$end"    >> "$out"

  mv "$out" "$file" || { rm -f "$tmp" "$out"; return 1; }
  chmod "$mode" "$file" 2>/dev/null || true
  rm -f "$tmp"
  return 0
}

# ---------------------------------------------------------------------------
# PHP checks
# ---------------------------------------------------------------------------

# The CLI PHP must match the web PHP in BOTH version and loaded extensions,
# otherwise `cv` misbehaves. This is called out in the CiviCRM requirements.
php_is_ok() {
  php -r 'exit(PHP_VERSION_ID >= 80200 ? 0 : 1);' 2>/dev/null
}

check_php_version() {
  local want="${1:-$CIVICRM_PHP_MIN}"
  php_is_ok || die "PHP >= ${want} required for CLI (found $(php -r 'echo PHP_VERSION;' 2>/dev/null || echo none))"
  log "CLI PHP $(php -r 'echo PHP_VERSION;')"
}

check_php_extensions() {
  local missing ext
  missing=""
  for ext in $CIVICRM_REQUIRED_EXTENSIONS; do
    php -m 2>/dev/null | tr 'A-Z' 'a-z' | grep -qx "$ext" || missing="${missing} ${ext}"
  done
  [ -z "$missing" ] || die "missing required PHP extensions:${missing}. Enable them in the PHP container (Jelastic: PHP > Extensions)."
  log "all required PHP extensions present"
}

# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

# The DB host is normally injected by the Jelastic `links` mechanism as
# DB_IP_ADDRESS, but resolve defensively so the script also works over SSH.
resolve_db_host() {
  # Default before use: every script runs under `set -u`, so referencing an
  # optional override that has not been set aborts the script.
  local override="${CIVICRM_DB_HOST:-}"
  if [ -n "$override" ]; then printf '%s' "$override"; return 0; fi
  local candidate
  for candidate in "${DB_IP_ADDRESS:-}" "${DB_HOST:-}" "${MYSQL_HOST:-}" "${DB_PRIVATE_IP:-}"; do
    [ -n "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  # Last resort: find the sqldb container by its Jelastic DNS hostname.
  awk '/[[:space:]]sqldb([[:space:]]|$)/ {print $1; exit}' /etc/hosts 2>/dev/null
}

# Is a MariaDB error code one that waiting cannot fix?
#   1045 access denied          - wrong user or password
#   1044 / 1049 unknown database - MARIADB_DATABASE did not create it
# Anything in the 2002/2003/2005 range is a connection problem, where waiting IS
# the right response, because the container may still be initialising.
db_error_is_terminal() {
  case "$1" in
    1045|1044|1049) return 0 ;;
    *)               return 1 ;;
  esac
}

# Wait until the database accepts the credentials CiviCRM will actually use.
#
# Probes with the mysql CLIENT, not PDO:
#   * it is present in the image, so this does not depend on pdo_mysql being
#     loaded (00-preflight.sh asserts that separately)
#   * its errors carry an explicit numeric code - "ERROR 1045 (28000): Access
#     denied..." - which is what lets us tell a wrong password from a container
#     that is not up yet
#
# That distinction matters. An earlier version probed as root with an empty
# password, which cannot work once MARIADB_ROOT_PASSWORD is set, and reported the
# single useless line "database did not become reachable after 120s".
wait_for_db() {
  local host; host="$(resolve_db_host)"
  [ -n "$host" ] || die "cannot determine database host. Set CIVICRM_DB_HOST."

  : "${CIVICRM_DB_NAME:=civicrm}"
  : "${CIVICRM_DB_USER:=civicrm}"
  : "${CIVICRM_DB_PASS:=}"
  : "${CIVICRM_DB_PORT:=3306}"
  [ -n "$CIVICRM_DB_PASS" ] || die "CIVICRM_DB_PASS must be provided to reach the database"

  local cli
  if   command -v mariadb >/dev/null 2>&1; then cli=mariadb
  elif command -v mysql   >/dev/null 2>&1; then cli=mysql
  else die "no mysql/mariadb client on this node; cannot verify the database"
  fi

  local tries=90        # 90 x 3s = 270s. MariaDB first-boot init is slow.
  local out code=""

  while [ "$tries" -gt 0 ]; do
    out="$("$cli" --connect-timeout=3 --protocol=TCP               -h "$host" -P "$CIVICRM_DB_PORT"               -u "$CIVICRM_DB_USER" "-p${CIVICRM_DB_PASS}"               -D "$CIVICRM_DB_NAME" -e 'SELECT 1' 2>&1)" && {
      log "database reachable at ${host}:${CIVICRM_DB_PORT} as ${CIVICRM_DB_USER}"
      return 0
    }

    code="$(printf '%s' "$out" | sed -n 's/^ERROR \([0-9][0-9]*\).*/\1/p' | head -1)"

    if db_error_is_terminal "$code"; then
      die "the database at ${host}:${CIVICRM_DB_PORT} refused these credentials:
    user ${CIVICRM_DB_USER}, database ${CIVICRM_DB_NAME}
    server said: $(printf '%s' "$out" | head -1)

  Error ${code}. 1045 is access denied; 1044/1049 mean the database is not there.

  The mariadb image creates the user and database from MARIADB_USER /
  MARIADB_PASSWORD / MARIADB_DATABASE, and ONLY on first start: if the volume at
  /var/lib/mysql already holds a database, those variables are ignored entirely.
  Delete the environment (or the volume) and re-import, or use the credentials
  already present in the volume."
    fi

    tries=$((tries - 1))
    if [ $((tries % 15)) -eq 0 ]; then
      log "still waiting for the database (${tries} attempts left)"
    fi
    sleep 3
  done

  die "the database at ${host}:${CIVICRM_DB_PORT} did not become reachable after $((90 * 3))s.
  Last error: $(printf '%s' "${out:-}" | head -1)

  That is a connection problem rather than a credentials one - nothing is
  listening, or the container is still initialising. Check the database node's
  status and logs in the dashboard."
}

# ---------------------------------------------------------------------------
# cv (CiviCRM CLI)
# ---------------------------------------------------------------------------
ensure_cv() {
  if [ -n "$CV_BIN" ] && [ -x "$CV_BIN" ]; then printf '%s' "$CV_BIN"; return 0; fi
  if command -v cv >/dev/null 2>&1; then command -v cv; return 0; fi

  local target="${HOME}/bin/cv"
  if [ ! -x "$target" ]; then
    mkdir -p "$(dirname "$target")"
    log "downloading cv CLI to ${target}"
    curl -fsSL "$CV_URL" -o "$target" \
      || die "failed to download cv from ${CV_URL}"
    chmod +x "$target"
  fi
  printf '%s' "$target"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

# Generate a site key when the caller did not supply one.
#
# CiviCRM requires the site key to be at least 32 characters of uniqueness.
# Filtering base64 output down to [A-Za-z0-9] also strips '+' and '/', so a fixed
# `head -c` can yield fewer characters than requested - keep drawing until the
# minimum is genuinely met rather than assuming a fixed input size is enough.
generate_site_key() {
  if [ -n "$CIVICRM_SITE_KEY" ]; then printf '%s' "$CIVICRM_SITE_KEY"; return 0; fi

  local key=""
  while [ "${#key}" -lt 40 ]; do
    key="${key}$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${key:0:40}"
}

# Is the site genuinely installed?
#
# NOT "does the file exist". A CiviCRM release ships a boilerplate
# private/civicrm.settings.php, so existence was never evidence of anything -
# and it deadlocked: the guard reported "already installed", the install was
# skipped forever, and CiviCRM kept showing its installer because the boilerplate
# carries no database settings. Nothing in the loop could break it.
#
# So require the settings that only a real install writes. The header of the
# boilerplate even says "CiviCRM version 5", which is a good illustration of how
# little the file's presence says.
civicrm_installed() {
  local app_root f n
  app_root="$(detect_app_root)"
  f="${app_root}/private/civicrm.settings.php"
  [ -f "$f" ] || return 1

  # LOAD the file and count what it defined, rather than pattern-matching its
  # source. Two earlier attempts grepped for $civicrm_setting['dsn'] and similar
  # and both were wrong: a genuine settings file from a release whose formatting
  # differs matched neither, so a completed install was reported as "missing".
  # Loading it is format-agnostic and is exactly what CiviCRM does.
  #
  # Run out-of-process: this file is PHP we do not control, and one die() taken
  # inline would abort the caller.
  n="$(php -r '
    $f = $argv[1];
    $tmp = @tempnam(sys_get_temp_dir(), "ci");
    if (!$tmp) { exit(1); }
    $child = "require \$argv[1]; \$d = null;"
           . " foreach ([\"civicrm_setting\",\"civicrm_config\",\"settings\"] as \$n) {"
           . "   if (isset(\$\$n) && is_array(\$\$n)) { \$d = \$\$n; break; } }"
           . " file_put_contents(\$argv[2], json_encode(\$d));";
    exec(escapeshellarg(PHP_BINARY) . " -d display_errors=0 -d error_reporting=0 -r "
        . escapeshellarg($child) . " " . escapeshellarg($f) . " " . escapeshellarg($tmp) . " 2>/dev/null");
    $d = json_decode(@file_get_contents($tmp), true);
    @unlink($tmp);
    if (!is_array($d)) { exit(1); }
    echo count($d);
  ' "$f" 2>/dev/null)" || return 1

  # A real install writes dozens of settings. The release boilerplate writes one
  # unrelated one. The threshold is deliberately low and the count is printed by
  # the caller so a near-miss is visible rather than silent.
  [ "${n:-0}" -ge 3 ]
}
