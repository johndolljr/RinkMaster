#!/usr/bin/env bash
# Builds RinkMaster with `swift build`.
#
# Usage:
#   scripts/build.sh [Debug|Release]
#
# Defaults to Debug.
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then sed -n '2,7p' "$0"; exit 0; fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
source "$HERE/lib.sh"
detect_build_target
CONFIGURATION="${1:-Debug}"
SPM_CONFIGURATION="$(spm_configuration "$CONFIGURATION")"
log "Building $SPM_EXECUTABLE ($SPM_CONFIGURATION)"
(cd "$REPO_ROOT" && swift build -c "$SPM_CONFIGURATION")
BIN_PATH="$(spm_bin_path "$SPM_CONFIGURATION")"
[[ -f "$BIN_PATH" ]] || die "Build reported success but binary not found at $BIN_PATH"
log "Built: $BIN_PATH"
