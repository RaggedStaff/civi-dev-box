#!/usr/bin/env bash
# 45-build-from-git.sh - run ON THE PHP CONTAINER.
#
# Builds the dfc_civicrm release archive from its GitHub repository and hands it
# to 45-deploy-archive.sh, which does the deployment.
#
# WHY THIS EXISTS
# ---------------
# The previous tooling asserted that the extension "has no git remote, so there
# is nothing to clone". That was wrong. The canonical source is public:
#
#     https://github.com/Food-Data-Collaboration/dfc-civicrm
#
# The claim came from looking at a local checkout that is actually a
# subdirectory of an unrelated repository (git remote
# git@github.com:zoro-jiro-san/The-Mansion.git) - so it had no remote *of its
# own*, and it also had no vendor/ at all, meaning it could not have produced a
# release either.
#
# What is true, and what this script handles:
#
#   * vendor/ and composer.lock are gitignored, so a clone needs
#     `composer install` before tools/build-release.sh will run. That works
#     because siol-data/dfc-connector is public on Packagist.
#   * composer.lock is NOT committed, so the resolved dependency versions are
#     not pinned. This is recorded in the log rather than hidden: a build from
#     source is reproducible in shape, not bit-for-bit.
#   * the archive lands at build/dfc_civicrm-<version>/dfc_civicrm-<version>.tar.gz,
#     not at the top of build/.
#
# USAGE
#   ./45-build-from-git.sh [--branch BRANCH] [--ref REF] [--skip-build] [-- ARGS...]
#
# Env: CIVICRM_EXT_KEY, CIVICRM_DATA_DIR, CIVICRM_EXT_BRANCH,
#      CIVICRM_EXT_REPO, CIVICRM_EXT_BUILD_DIR
set -euo pipefail
# shellcheck source=lib.sh
_CIVI_SELF="${BASH_SOURCE[0]:-$0}"
. "$(dirname "$_CIVI_SELF")/lib.sh" || {
  echo "civi: cannot source lib.sh (looked next to '${_CIVI_SELF}')" >&2
  exit 1
}

EXT_KEY="${CIVICRM_EXT_KEY:-dfc_civicrm}"
REPO="${CIVICRM_EXT_REPO:-https://github.com/Food-Data-Collaboration/dfc-civicrm.git}"
BRANCH="${CIVICRM_EXT_BRANCH:-main}"
REF=""
SKIP_BUILD=0
DEPLOY_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --branch)  BRANCH="$2"; shift 2 ;;
    --ref)     REF="$2"; shift 2 ;;
    --repo)    REPO="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --) shift; DEPLOY_ARGS=("$@"); break ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) DEPLOY_ARGS+=("$1"); shift ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git is not on this node"

# Keep the checkout off the container's ephemeral filesystem so a redeploy does
# not force a full re-clone, but inside the data dir so it is ours to wipe.
BUILD_ROOT="${CIVICRM_EXT_BUILD_DIR:-${CIVICRM_DATA_DIR:-/var/lib/civicrm-data}/build}"
SRC="${BUILD_ROOT}/$(basename "${REPO%.git}")"
mkdir -p "$BUILD_ROOT"

log "=== build ${EXT_KEY} from git ==="
log "repo:   ${REPO}"
log "branch: ${BRANCH}${REF:+ @ ${REF}}"

# --- Fetch --------------------------------------------------------------------
if [ -d "${SRC}/.git" ]; then
  log "updating the existing checkout at ${SRC}"
  git -C "$SRC" fetch --quiet --depth 1 origin "$BRANCH" \
    || die "could not fetch ${BRANCH} from ${REPO}"
else
  mkdir -p "$SRC"
  git -C "$SRC" init --quiet
  git -C "$SRC" remote add origin "$REPO" 2>/dev/null || git -C "$SRC" remote set-url origin "$REPO"
  git -C "$SRC" fetch --quiet --depth 1 origin "$BRANCH" \
    || die "could not fetch ${BRANCH} from ${REPO}"
fi

if [ -n "$REF" ]; then
  git -C "$SRC" fetch --quiet --depth 1 origin "$REF" || die "could not fetch ref ${REF}"
  git -C "$SRC" checkout --quiet --detach FETCH_HEAD
else
  git -C "$SRC" checkout --quiet -B "$BRANCH" FETCH_HEAD
fi
COMMIT="$(git -C "$SRC" rev-parse --short HEAD)"
log "at commit ${COMMIT}"

# --- Sanity: is this the extension we think it is? ----------------------------
INFO="${SRC}/info.xml"
[ -f "$INFO" ] || die "no info.xml at the repository root.
  CiviCRM extensions are packaged with info.xml at the top level, not in a
  subdirectory named after the key."
FOUND_KEY="$(php "$(dirname "${_CIVI_SELF}")/read-attr.php" "$INFO" key 2>/dev/null || true)"
if [ -n "$FOUND_KEY" ] && [ "$FOUND_KEY" != "$EXT_KEY" ]; then
  die "repository declares key='${FOUND_KEY}', expected '${EXT_KEY}'.
  Deploying it under ${EXT_KEY} would produce an extension CiviCRM cannot load."
fi
log "info.xml key: ${FOUND_KEY:-${EXT_KEY}}"

# --- Dependencies -------------------------------------------------------------
# Only when vendor/ is missing, so a rebuild is fast.
if [ ! -d "${SRC}/vendor/siol-data" ]; then
  command -v composer >/dev/null 2>&1 || die "composer is not on this node and vendor/ is missing.
  vendor/ is gitignored, so a clone cannot build without running
  'composer install' first."
  log "installing dependencies (vendor/ is gitignored)"
  [ -f "${SRC}/composer.lock" ] || warn "no composer.lock in the repository - dependency
  versions are resolved fresh at build time, so this build is not bit-reproducible."
  ( cd "$SRC" && COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --no-interaction --prefer-dist --quiet ) \
    || die "composer install failed. On this node it needs ext-dom, ext-mbstring,
    ext-json and ext-libxml, plus outbound access to repo.packagist.org."
  [ -d "${SRC}/vendor/siol-data" ] || die "composer install did not produce vendor/siol-data.
    The release runtime (siol-data/dfc-connector) is what makes the extension
    able to serialise JSON-LD."
fi

# --- Build --------------------------------------------------------------------
if [ "$SKIP_BUILD" -eq 1 ] && [ -d "${SRC}/build" ]; then
  log "reusing the existing build/ (--skip-build)"
else
  # build-release.sh refuses to reuse an existing run directory and has no flag
  # to override that - its --force is about a dirty git tree, not the output
  # directory. Its own message says to remove it "if you are sure nothing else
  # uses it". We are: this is build output inside our own clone, under a build
  # root we own. Removing it is what makes a second run work at all; without
  # this the script succeeds once and fails on every rebuild after.
  BUILD_OUT="${SRC}/build"
  if [ -e "$BUILD_OUT" ]; then
    case "$BUILD_OUT" in
      "${BUILD_ROOT}"/*)
        log "clearing the previous build output at ${BUILD_OUT}"
        rm -rf -- "$BUILD_OUT"
        ;;
      *)
        die "refusing to remove ${BUILD_OUT}: it is not under ${BUILD_ROOT}"
        ;;
    esac
  fi
  log "running the extension's own tools/build-release.sh"
  ( cd "$SRC" && bash tools/build-release.sh ) || die "tools/build-release.sh failed"
fi

ARCHIVE="$(find "${SRC}/build" -name "${EXT_KEY}-*.tar.gz" -type f 2>/dev/null | sort | tail -1)"
[ -n "$ARCHIVE" ] || die "no ${EXT_KEY}-*.tar.gz under ${SRC}/build.
  tools/build-release.sh writes build/${EXT_KEY}-<version>/${EXT_KEY}-<version>.tar.gz"

log "archive: ${ARCHIVE} ($(wc -c < "$ARCHIVE") bytes)"

# Verify the extension's own checksum if it published one next to the archive.
SUMS="$(dirname "$ARCHIVE")/SHA256SUMS"
if [ -f "$SUMS" ] && command -v sha256sum >/dev/null 2>&1; then
  if ( cd "$(dirname "$ARCHIVE")" && sha256sum --check --status SHA256SUMS ); then
    log "SHA256SUMS verified"
  else
    warn "SHA256SUMS did not verify - continuing, but the archive may be truncated"
  fi
fi

# --- Deploy -------------------------------------------------------------------
DEPLOYER="$(dirname "${_CIVI_SELF}")/45-deploy-archive.sh"
[ -f "$DEPLOYER" ] || die "45-deploy-archive.sh not found beside this script"

# The deployer reads these from the environment, not from our local variables.
# Without them it dies on "extension key not set", which reads like a bug here
# rather than a missing handoff.
export CIVICRM_EXT_KEY="$EXT_KEY"
export CIVICRM_DATA_DIR="${CIVICRM_DATA_DIR:-${BUILD_ROOT%/build}}"

if [ "${#DEPLOY_ARGS[@]}" -eq 0 ]; then
  log "deploying"
  exec bash "$DEPLOYER" "$ARCHIVE"
else
  log "deploying with extra arguments: ${DEPLOY_ARGS[*]}"
  exec bash "$DEPLOYER" "${DEPLOY_ARGS[@]}" "$ARCHIVE"
fi