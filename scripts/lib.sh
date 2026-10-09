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
  if [ -n "$CIVICRM_DB_HOST" ]; then printf '%s' "$CIVICRM_DB_HOST"; return 0; fi
  local candidate
  for candidate in "${DB_IP_ADDRESS:-}" "${DB_HOST:-}" "${MYSQL_HOST:-}" "${DB_PRIVATE_IP:-}"; do
    [ -n "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  # Last resort: find the sqldb container by its Jelastic DNS hostname.
  awk '/[[:space:]]sqldb([[:space:]]|$)/ {print $1; exit}' /etc/hosts 2>/dev/null
}

wait_for_db() {
  local host; host="$(resolve_db_host)"
  [ -n "$host" ] || die "cannot determine database host. Set CIVICRM_DB_HOST."

  local tries=60
  while [ "$tries" -gt 0 ]; do
    if php -r '
      $h = getenv("H"); $p = (int) getenv("P");
      try { $pdo = new PDO("mysql:host=$h;port=$p", "root", "", [PDO::ATTR_TIMEOUT => 3]);
            exit(0); }
      catch (Throwable $e) { exit(1); }
    ' H="$host" P="$CIVICRM_DB_PORT" 2>/dev/null; then
      log "database reachable at ${host}:${CIVICRM_DB_PORT}"
      return 0
    fi
    tries=$((tries - 1))
    sleep 2
  done
  die "database did not become reachable at ${host}:${CIVICRM_DB_PORT} after $((60 * 2))s"
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

civicrm_installed() {
  local app_root; app_root="$(detect_app_root)"
  [ -f "${app_root}/private/civicrm.settings.php" ]
}
