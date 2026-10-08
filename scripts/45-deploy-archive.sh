#!/usr/bin/env bash
# 45-deploy-archive.sh - run ON THE PHP CONTAINER.
#
# Deploys a prebuilt extension archive into the site's ext-dir, registers it
# with cv, and applies its database migrations.
#
# This is the primary deploy path for dfc_civicrm, because:
#   * it has no git remote, so there is nothing to clone
#   * vendor/ and composer.lock are gitignored, so a clone would be missing the
#     siol-data/dfc-connector runtime subset that export depends on at runtime
#   * tools/build-release.sh already subsets vendor/ via an allow-list, so the
#     archive is the correct deployable unit
#
# It also exposes what tools/verify-install.sh expects from the box:
#   cv ext:dir, cv ext:enable, cv ext:disable, cv ext:status, cv sql:query
#
# USAGE
#   ./45-deploy-archive.sh <archive.tar.gz>
#   ./45-deploy-archive.sh --ext <key> <archive.tar.gz>
#   ./45-deploy-archive.sh --sql-only
#   ./45-deploy-archive.sh --remove
#
# Env: CIVICRM_EXT_KEY, CIVICRM_DATA_DIR
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXT_KEY="${CIVICRM_EXT_KEY:-}"
ARCHIVE=""
SQL_ONLY=0
REMOVE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --ext)      EXT_KEY="${2:-}"; shift 2 ;;
        --sql-only) SQL_ONLY=1; shift ;;
        --remove)   REMOVE=1; shift ;;
        -h|--help)  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)         die "unknown option: $1" ;;
        *)          [ -z "$ARCHIVE" ] || die "more than one archive given: $1 and $ARCHIVE"
                    ARCHIVE="$1"; shift ;;
    esac
done

log "=== archive deploy (key=${EXT_KEY:-unset}) ==="
[ -n "$EXT_KEY" ] || die "extension key not set (--ext or CIVICRM_EXT_KEY)"

APP_ROOT="$(detect_app_root)"
CIVICRM_APP_DIR="$APP_ROOT"
cd "$APP_ROOT"

ensure_data_dirs
link_data_dirs
civicrm_installed || die "CiviCRM is not installed yet (no private/civicrm.settings.php). Run 30-install-civicrm.sh first."
log "site is installed"

CV="$(ensure_cv)"
EXT_DIR="$(data_ext)"
TARGET="${EXT_DIR}/${EXT_KEY}"

# --- Remove ---------------------------------------------------------------
if [ "$REMOVE" -eq 1 ]; then
    log "disabling extension"
    "$CV" ext:disable "$EXT_KEY" -v || warn "ext:disable returned non-zero"
    if [ -d "$TARGET" ] && [ ! -L "$TARGET" ]; then
        mv "$TARGET" "${TARGET}.removed.$(date +%s)"
        log "moved ${TARGET} aside (data preserved; re-run with the archive to restore)"
    fi
    log "=== removed ==="
    exit 0
fi

# --- Migrations only ------------------------------------------------------
if [ "$SQL_ONLY" -eq 1 ]; then
    log "applying pending database upgrades for ${EXT_KEY}"
    "$CV" upgrade:sql --ext="$EXT_KEY" -v
    "$CV" cache:clear 2>/dev/null || true
    log "=== sql-only done ==="
    exit 0
fi

[ -n "$ARCHIVE" ] || die "no archive given. Usage: $0 [--ext <key>] <archive.tar.gz>"
[ -f "$ARCHIVE" ] || die "archive not found: ${ARCHIVE}"

# --- Validate the archive BEFORE touching the site -------------------------
# Every check here is one that is expensive to discover after a half-install.
log "archive: ${ARCHIVE} ($(du -h "$ARCHIVE" | cut -f1))"

if [ -f "${ARCHIVE}.sha256" ] || [ -f "${ARCHIVE%.tar.gz}.sha256" ]; then
    SUMFILE="${ARCHIVE}.sha256"; [ -f "$SUMFILE" ] || SUMFILE="${ARCHIVE%.tar.gz}.sha256"
    log "verifying checksum"
    ( cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$SUMFILE")" ) \
        || die "checksum mismatch for $(basename "$ARCHIVE")"
    log "checksum OK"
fi

MEMBERS="$(tar tzf "$ARCHIVE")"

# CiviCRM resolves <ext-dir>/<key>/<file>.php, so the archive's single top-level
# directory MUST equal the extension key.
TOP_COUNT="$(printf '%s\n' "$MEMBERS" | awk -F/ 'NF {print $1}' | sort -u | grep -c .)"
[ "$TOP_COUNT" -eq 1 ] \
    || die "archive must contain exactly one top-level directory; found $(printf '%s\n' "$MEMBERS" | awk -F/ 'NF{print $1}' | sort -u | tr '\n' ' ')"
TOP="$(printf '%s\n' "$MEMBERS" | awk -F/ 'NF {print $1}' | sort -u)"
[ "$TOP" = "$EXT_KEY" ] \
    || die "top-level directory '${TOP}' does not match extension key '${EXT_KEY}'. CiviCRM resolves <ext-dir>/<key>/<file>.php, so these MUST agree."

BOOT="$(printf '%s\n' "$MEMBERS" | grep -E "^${EXT_KEY}/[^/]+\.php$" | head -1 || true)"
[ -n "$BOOT" ] || die "no root-level .php boot file in ${EXT_KEY}/"
log "boot file: ${BOOT}"

# info.xml is what makes CiviCRM's scanner recognise the directory at all.
printf '%s\n' "$MEMBERS" | grep -qx "${EXT_KEY}/info.xml" \
    || die "archive has no ${EXT_KEY}/info.xml"

# dfc_civicrm reads connector contexts/ and vocabularies/ off disk at runtime.
# Its own preflight calls this out: losing either breaks export with a "file not
# found" rather than an obvious missing-vendor error.
#
# Match a real member under each dir, not just the directory entry - a bare
# path test can pass on some tar implementations for an empty dir.
CONNECTOR="vendor/siol-data/dfc-connector/php-connector"
HAVE=0
for d in src contexts vocabularies; do
    if printf '%s\n' "$MEMBERS" | grep -q "^${EXT_KEY}/${CONNECTOR}/${d}/[^/]"; then
        HAVE=$((HAVE + 1))
    else
        warn "archive is missing ${CONNECTOR}/${d}/"
    fi
done
[ "$HAVE" -eq 3 ] \
    || die "archive is missing part of the vendored DFC connector subset (${HAVE}/3 dirs present).
    dfc_civicrm needs it at runtime for export. Rebuild on your workstation
    WITHOUT --no-vendor:
      cd <dfc_civicrm checkout> && tools/build-release.sh --force"
log "vendored connector subset: OK (src, contexts, vocabularies)"

# --- Install ---------------------------------------------------------------
log "installing into ${TARGET}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
tar xzf "$ARCHIVE" -C "$STAGE"

# Keep any existing copy recoverable.
if [ -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
    BACKUP="${TARGET}.bak.$(date +%s)"
    log "existing install found - moving aside to ${BACKUP}"
    mv "$TARGET" "$BACKUP"
fi

cp -a "${STAGE}/${EXT_KEY}" "$TARGET"
log "extracted to ${TARGET}"

[ -f "${TARGET}/info.xml" ] || die "extracted copy has no info.xml"

# --- Register + migrate ----------------------------------------------------
log "registering: cv ext:enable ${EXT_KEY}"
if "$CV" status 2>/dev/null | grep -qi "$EXT_KEY"; then
    log "already registered - refreshing"
    "$CV" ext:enable "$EXT_KEY" -v || warn "ext:enable returned non-zero"
else
    "$CV" ext:enable "$EXT_KEY" -v \
        || die "cv ext:enable failed. Likely causes:
    - php_compatibility excludes the running PHP (dfc_civicrm declares 8.1-8.4;
      the box runs 8.4.26. If you raised phpTag to 8.5 this WILL fail.)
    - <key> in info.xml does not match the directory name
    - a required mixin could not be fetched (entity-types-php, mgd-php,
      menu-xml, setting-admin, smarty)"
fi

log "applying pending database upgrades"
"$CV" upgrade:sql --ext="$EXT_KEY" -v \
    || warn "upgrade:sql reported a problem - inspect private/log/"

"$CV" cache:clear 2>/dev/null || true

# --- Report ----------------------------------------------------------------
VERSION="$(php -r '$x=@simplexml_load_file($argv[1]); echo $x ? (string)$x->version : "unknown";' "${TARGET}/info.xml" 2>/dev/null || echo unknown)"
PCOMPAT="$(php -r '$x=@simplexml_load_file($argv[1]); $n=$x?$x->xpath("//php_compatibility/ver"):null; echo $n ? implode(", ", array_map("strval", $n)) : "not declared";' "${TARGET}/info.xml" 2>/dev/null || echo '?')"
log "-------------------------------------------------------------"
log "extension  : ${EXT_KEY} ${VERSION}"
log "php compat : declared ${PCOMPAT} / running $(php -r 'echo PHP_VERSION;')"
log "path       : ${TARGET}"
log "============================================================="
log "next: tools/verify-install.sh --cv ${CV} --base-url http://localhost"
log "=== archive deploy complete ==="
