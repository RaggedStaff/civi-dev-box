#!/usr/bin/env bash
# Run a civi-dev-box script on the box over SSH, as a FILE.
#
# Why this exists: the Makefile used to do `ssh host 'bash -s' < script.sh`, which
# pipes the script into bash's stdin. When a script arrives on stdin,
# BASH_SOURCE is unset, so every script's `. lib.sh` line resolves to "/lib.sh"
# and the run dies with:
#
#     BASH_SOURCE[0]: unbound variable
#     /lib.sh: No such file or directory
#
# That is the same failure that killed every JPS import until the hooks were
# changed to download scripts to disk. The Makefile still had it.
#
# So: push the script AND lib.sh into a directory on the box, then execute the
# file. Arguments after the script name are passed through.
set -euo pipefail

SCRIPT="${1:?usage: ssh-run.sh <script.sh> [args...]}"
[ -f "$SCRIPT" ] || { echo "no such script: ${SCRIPT}" >&2; exit 1; }
shift

# Resolve lib.sh next to the script, the way the scripts expect.
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT")" && pwd)"
LIB="${SCRIPT_DIR}/lib.sh"
[ -f "$LIB" ] || { echo "lib.sh not found next to ${SCRIPT}" >&2; exit 1; }

REMOTE_DIR="${CIVICRM_REMOTE_SCRIPTS_DIR:-/var/lib/jelastic/scripts}"
SSH_USER="${CIVICRM_SSH_USER:-root}"
SSH_TARGET="${CIVICRM_SSH_TARGET:-civi-dev}"
SSH_KEY="${CIVICRM_SSH_KEY:-}"

# Split into an argv array. Unquoted ${SSH_OPTS} expands to nothing when no key
# is given, which scp then reads as a filename ("cannot stat ' root@civi-dev'").
SSH_ARGS=()
[ -n "$SSH_KEY" ] && SSH_ARGS+=(-i "$SSH_KEY")
SSH="${SSH_USER}@${SSH_TARGET}"

mkdir -p "$REMOTE_DIR"
scp "${SSH_ARGS[@]}" -q "$SCRIPT" "$LIB" "${SSH}:${REMOTE_DIR}/"

# Quote each argument so a URL or password with shell metacharacters survives.
printf -v ARGS ' %q' "$@"

# No `bash -s`: the script is a file, so BASH_SOURCE resolves and lib.sh loads.
REMOTE="${REMOTE_DIR}/$(basename "$SCRIPT")"
ssh "${SSH_ARGS[@]}" "${SSH}" \
  "test -f '${REMOTE}' || { echo 'push failed: ${REMOTE} is not on the box' >&2; exit 1; }; bash '${REMOTE}'${ARGS}"