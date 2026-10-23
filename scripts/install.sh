#!/usr/bin/env bash
# Builds a release RinkMaster and installs it as ~/Applications/RinkMaster.app.
#
# Usage:
#   scripts/install.sh
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then sed -n '2,5p' "$0"; exit 0; fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
source "$HERE/lib.sh"
detect_build_target
"$HERE/build.sh" Release
INSTALL_DIR="$HOME/Applications"; DEST="$INSTALL_DIR/${SPM_EXECUTABLE}.app"
SRC="$(spm_bin_path release)"
[[ -f "$SRC" ]] || die "Binary not found at $SRC"
mkdir -p "$INSTALL_DIR"
[[ -d "$DEST" ]] && { log "Removing previous install at $DEST"; rm -rf "$DEST"; }
log "Assembling $SPM_EXECUTABLE.app"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$SRC" "$DEST/Contents/MacOS/$SPM_EXECUTABLE"
# fonts live in the app bundle (Contents/Resources/Fonts); the SwiftPM resource bundle is only used for dev runs
mkdir -p "$DEST/Contents/Resources/Fonts"
cp "$REPO_ROOT"/Sources/"$SPM_EXECUTABLE"/Resources/Fonts/*.ttf "$DEST/Contents/Resources/Fonts/"
# the MCP server ships inside the app bundle so there is one thing to install and one path to register with agents
MCP_SRC="$(dirname "$SRC")/rinkmaster-mcp"
[[ -f "$MCP_SRC" ]] || die "MCP server not built at $MCP_SRC"
cp "$MCP_SRC" "$DEST/Contents/MacOS/rinkmaster-mcp"
ICON_NAME=""
if [[ -f "$REPO_ROOT/Resources/AppIcon.icns" ]]; then
  cp "$REPO_ROOT/Resources/AppIcon.icns" "$DEST/Contents/Resources/AppIcon.icns"; ICON_NAME="AppIcon"
fi
spm_write_app_info_plist "$DEST/Contents/Info.plist" "$ICON_NAME"
# Sign with a stable identity so macOS keeps the app's Local Network permission across reinstalls (ad-hoc signing makes
# every build look like a new app). Override with RINKMASTER_SIGN_IDENTITY; falls back to ad-hoc if none is available.
IDENTITY="${RINKMASTER_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
if [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" --identifier com.ragingcoders.RinkMaster.mcp "$DEST/Contents/MacOS/rinkmaster-mcp" 2>/dev/null \
   && codesign --force --sign "$IDENTITY" --identifier com.ragingcoders.RinkMaster "$DEST" 2>/dev/null; then
  log "Signed with: $IDENTITY"
else
  codesign --force --sign - "$DEST/Contents/MacOS/rinkmaster-mcp" 2>/dev/null || true
  codesign --force --sign - "$DEST" 2>/dev/null || true
  log "Signed ad-hoc (no signing identity found); Local Network permission will be asked again after each install"
fi
log "Installed $SPM_EXECUTABLE to $DEST"
