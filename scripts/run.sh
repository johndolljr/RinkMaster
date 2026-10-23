#!/usr/bin/env bash
# Builds (unless --no-build) and launches RinkMaster.
#
# Usage:
#   scripts/run.sh [Debug|Release] [--no-build]
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then sed -n '2,6p' "$0"; exit 0; fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
source "$HERE/lib.sh"
detect_build_target
CONFIGURATION="Debug"; SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    Debug|Release) CONFIGURATION="$arg" ;;
    --no-build) SKIP_BUILD=1 ;;
    *) die "Unknown argument '$arg'" ;;
  esac
done
[[ "$SKIP_BUILD" -eq 1 ]] || "$HERE/build.sh" "$CONFIGURATION"
BIN_PATH="$(spm_bin_path "$(spm_configuration "$CONFIGURATION")")"
[[ -f "$BIN_PATH" ]] || die "Binary not found at $BIN_PATH (run scripts/build.sh first)"
log "Launching $BIN_PATH"
exec "$BIN_PATH"
