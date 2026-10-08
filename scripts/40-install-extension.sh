#!/usr/bin/env bash
# 40-install-extension.sh - run ON THE PHP CONTAINER.
#
# Deploys the native extension under test into the running CiviCRM site and
# applies its database migrations.
#
#   ./40-install-extension.sh              # install or update
#   ./40-install-extension.sh --reinstall  # remove then re-add the extension
#   ./40-install-extension.sh --sql-only   # just run pending DB upgrades
#
# CiviCRM discovers extensions by scanning the ext-dir (private/civicrm.settings.php
# -> ext-dir, default <project-root>/ext) for directories containing an
# info.xml that declares <extension> files. Because our ext/ lives on a
# persistent volume, the extension survives container redeploys.
#
# Two wiring modes:
#   link     (default) symlink the source into ext/<key>. Layout independent -
#            works with the release tarball and with the composer template.
#   composer             add a Composer *path repository* for the extension and
#            let Composer resolve it into the project. Use this when the site was
#            installed from the composer project template and you want Composer to
#            own the dependency graph (also lets the extension pull its own deps).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="link"
REINSTALL=0
SQL_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --reinstall) REINSTALL=1 ;;
    --sql-only)  SQL_ONLY=1 ;;
    --composer)  MODE="composer" ;;
    --link)      MODE="link" ;;
    *) die "unknown argument: $arg" ;;
  esac
done

log "=== extension deploy (mode=${MODE}) ==="

# --- Validate cheap inputs before doing any network or filesystem work -------
# `ensure_cv` downloads the CLI, and fetch_source clones. Neither should happen
# if we are going to die anyway.
[ -n "$CIVICRM_EXT_KEY" ] || die "CIVICRM_EXT_KEY must be set (the extension key from info.xml)"

# A full deploy needs to know where the source is; --sql-only does not.
if [ "$SQL_ONLY" -eq 0 ]; then
  [ -n "$CIVICRM_EXT_SOURCE" ] \
    || die "CIVICRM_EXT_SOURCE must be a git URL or a local directory (required unless --sql-only)"
fi

APP_ROOT="$(detect_app_root)"
CIVICRM_APP_DIR="$APP_ROOT"
cd "$APP_ROOT"

ensure_data_dirs
link_data_dirs

EXT_DIR="$(data_ext)"
EXT_TARGET="${EXT_DIR}/${CIVICRM_EXT_KEY}"

# --- Verify the site is installed before touching extensions -----------------
civicrm_installed || die "CiviCRM is not installed yet (private/civicrm.settings.php missing). Run 30-install-civicrm.sh first."
log "site is installed"

CV="$(ensure_cv)"

# ===========================================================================
# SQL only
# ===========================================================================
if [ "$SQL_ONLY" -eq 1 ]; then
  log "applying pending database upgrades for ${CIVICRM_EXT_KEY}"
  "$CV" upgrade:sql --ext="$CIVICRM_EXT_KEY" -v
  "$CV" cache:clear 2>/dev/null || true
  log "=== sql-only done ==="
  exit 0
fi

# ===========================================================================
# Materialise the extension source
# ===========================================================================
# Staged on persistent storage so a redeploy (which wipes the app tree) does not
# require re-cloning.
STAGE="${CIVICRM_DATA_DIR}/src/${CIVICRM_EXT_KEY}"

fetch_source() {
  [ -n "$CIVICRM_EXT_SOURCE" ] || die "CIVICRM_EXT_SOURCE must be a git URL or a local directory"

  if [ -d "$CIVICRM_EXT_SOURCE" ]; then
    log "copying extension source from ${CIVICRM_EXT_SOURCE}"
    mkdir -p "$STAGE"
    # rsync if available so deletions propagate; otherwise replace wholesale.
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete --exclude '.git' "${CIVICRM_EXT_SOURCE}/" "${STAGE}/"
    else
      rm -rf "$STAGE"
      mkdir -p "$STAGE"
      cp -a "${CIVICRM_EXT_SOURCE}/." "$STAGE/"
    fi
    return 0
  fi

  case "$CIVICRM_EXT_SOURCE" in
    git@*|ssh://*|http://*|https://*|git://*|file://*)
      log "cloning ${CIVICRM_EXT_SOURCE}"
      if [ -d "${STAGE}/.git" ]; then
        git -C "$STAGE" fetch --all --tags --prune
        git -C "$STAGE" checkout --force "${CIVICRM_EXT_BRANCH:-HEAD}"
        git -C "$STAGE" pull --ff-only 2>/dev/null || git -C "$STAGE" reset --hard "origin/${CIVICRM_EXT_BRANCH:-$(git -C "$STAGE" rev-parse --abbrev-ref HEAD)}"
      else
        rm -rf "$STAGE"
        git clone --depth 1 ${CIVICRM_EXT_BRANCH:+--branch "$CIVICRM_EXT_BRANCH"} "$CIVICRM_EXT_SOURCE" "$STAGE"
      fi
      ;;
    *)
      die "CIVICRM_EXT_SOURCE is neither an existing directory nor a recognised git URL: ${CIVICRM_EXT_SOURCE}"
      ;;
  esac
}

fetch_source

# A CiviCRM extension must ship an info.xml declaring <extension> files.
INFO_XML="$(find "$STAGE" -maxdepth 2 -name 'info.xml' -print -quit)"
[ -n "$INFO_XML" ] || die "no info.xml found in ${STAGE} - this does not look like a CiviCRM extension"

if ! grep -q '<extension' "$INFO_XML"; then
  die "${INFO_XML} does not contain an <extension> file declaration"
fi
log "info.xml: ${INFO_XML##*/}"

# --- Composer-managed extension build step ---------------------------------
# Many extensions ship JS/CSS that must be built. Run it if a build is declared.
if [ -f "${STAGE}/package.json" ]; then
  if command -v npm >/dev/null 2>&1; then
    log "package.json present - building extension assets"
    ( cd "$STAGE" && [ -f package-lock.json ] && npm ci --no-audit --no-fund || npm install --no-audit --no-fund ) \
      || warn "npm install failed; continuing (the extension may be partially functional)"
    if grep -q '"build"' "${STAGE}/package.json" 2>/dev/null; then
      ( cd "$STAGE" && npm run build ) || warn "npm run build failed; continuing"
    fi
  else
    warn "package.json present but npm is unavailable - assets not built"
  fi
fi

# ===========================================================================
# Wire it into ext/
# ===========================================================================
if [ "$MODE" = "composer" ]; then
  [ -f "${APP_ROOT}/composer.json" ] \
    || die "composer mode requires a composer.json in ${APP_ROOT}. The release tarball has none - install CiviCRM via the composer project template, or use --link."
  command -v composer >/dev/null 2>&1 || die "composer is not available in this container"

  log "registering Composer path repository for ${STAGE}"
  # A path repository keeps Composer in charge of the dependency graph while
  # still letting us point at a working tree that changes on every iteration.
  php -r '
    $root = $argv[1]; $stage = $argv[2]; $key = $argv[3];
    $file = $root . "/composer.json";
    $json = json_decode(file_get_contents($file), true);
    $json["repositories"] = $json["repositories"] ?? [];
    $repos = array_filter($json["repositories"], fn($r) => !isset($r["url"]) || $r["url"] !== $stage);
    array_unshift($repos, ["type" => "path", "url" => $stage, "options" => ["symlink" => true, "versions" => []]]);
    $json["repositories"] = $repos;
    file_put_contents($file, json_encode($json, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
    echo "path repository added for {$key}\n";
  ' "$APP_ROOT" "$STAGE" "$CIVICRM_EXT_KEY"

  log "composer update (this resolves the extension into the project)"
  composer update --no-interaction --no-progress -W || die "composer update failed"

  # Composer decides where it lands; make sure CiviCRM's ext-dir agrees.
  VENDORED=""
  for candidate in "${APP_ROOT}/vendor/civicrm/${CIVICRM_EXT_KEY}" "${APP_ROOT}/vendor/${CIVICRM_EXT_KEY}"; do
    [ -d "$candidate" ] && { VENDORED="$candidate"; break; }
  done
  if [ -z "$VENDORED" ]; then
    warn "could not locate the composer-installed extension; relying on ext-dir discovery"
  else
    log "extension resolved by composer at ${VENDORED}"
    ln -sfn "$VENDORED" "$EXT_TARGET"
  fi
else
  log "symlinking ${STAGE} -> ${EXT_TARGET}"
  ln -sfn "$STAGE" "$EXT_TARGET"
fi

# ===========================================================================
# Register + migrate
# ===========================================================================
if [ "$REINSTALL" -eq 1 ]; then
  log "--reinstall: removing existing registration first"
  "$CV" ext:disable "$CIVICRM_EXT_KEY" 2>/dev/null || warn "ext:disable failed (was it installed?)"
  ln -sfn "$STAGE" "$EXT_TARGET"
fi

if "$CV" status 2>/dev/null | grep -qi "$CIVICRM_EXT_KEY"; then
  log "extension already registered - refreshing instead of re-adding"
  "$CV" ext:enable "$CIVICRM_EXT_KEY" -v || warn "ext:enable returned non-zero"
else
  log "registering extension: cv ext:enable ${CIVICRM_EXT_KEY}"
  "$CV" ext:enable "$CIVICRM_EXT_KEY" -v \
    || die "cv ext:enable failed. Run with -vv and inspect the error above; common causes are a missing <civicrm> requirement in info.xml or a missing SQL/UPGRADE file."
fi

# Pending DB migrations for this extension.
log "applying pending database upgrades"
"$CV" upgrade:sql --ext="$CIVICRM_EXT_KEY" -v \
  || warn "upgrade:sql reported a problem - inspect private/log/ for detail"

"$CV" cache:clear 2>/dev/null || true

# --- Report ----------------------------------------------------------------
log "-------------------------------------------------------------"
log "extension: ${CIVICRM_EXT_KEY}"
log "source:    ${STAGE}"
log "mounted:   ${EXT_TARGET} -> $(readlink -f "$EXT_TARGET")"
log "url:       ${CIVICRM_SITE_URL:-${env.url}}/civicrm/admin/extension"
log "============================================================="
log "=== extension deploy complete ==="
