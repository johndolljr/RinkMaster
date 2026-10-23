#!/usr/bin/env bash
# Installs the DLL Arcade EmulationStation theme (themes/dll-arcade) on a cabinet.
#
# Usage:
#   scripts/install-theme.sh USER@HOST            # copy the theme; pick it in ES: START > UI SETTINGS > THEME SET
#   scripts/install-theme.sh USER@HOST --activate # also make it the active theme (ES restarts when it next quits; see below)
#
# The theme goes to /opt/retropie/configs/all/emulationstation/themes/dll-arcade (owned by the RetroPie user).
# --activate edits ThemeSet in es_settings.cfg; EmulationStation rewrites that file when it exits, so it only sticks when ES
# is not running or is restarted afterwards from a state where it already holds the new value.
# Needs key-based SSH and passwordless sudo for USER on HOST.
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -eq 0 ]]; then sed -n '2,12p' "$0"; exit 0; fi
TARGET="$1"; shift
ACTIVATE=0; [[ "${1:-}" == "--activate" ]] && ACTIVATE=1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$HERE/themes/dll-arcade"
DEST=/opt/retropie/configs/all/emulationstation/themes/dll-arcade
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$TARGET")

python3 -c "import sys, xml.dom.minidom as m; m.parse(sys.argv[1])" "$SRC/theme.xml"
echo "==> Copying the theme to $TARGET"
"${SSH[@]}" "mkdir -p /tmp/dll-arcade-theme"
rsync -rlt --delete -e "ssh -o BatchMode=yes" "$SRC/" "$TARGET:/tmp/dll-arcade-theme/"
"${SSH[@]}" "sudo bash -s" <<REMOTE
set -euo pipefail
owner=\$(stat -c %U /opt/retropie/configs/all/emulationstation)
mkdir -p "$DEST"
rsync -rlt --delete /tmp/dll-arcade-theme/ "$DEST/"
chown -R "\$owner:\$owner" /opt/retropie/configs/all/emulationstation/themes
rm -rf /tmp/dll-arcade-theme
if [[ $ACTIVATE -eq 1 ]]; then
  cfg=/opt/retropie/configs/all/emulationstation/es_settings.cfg
  cp -p "\$cfg" "\$cfg.bak-theme"
  if grep -q 'name="ThemeSet"' "\$cfg"; then sed -i 's|<string name="ThemeSet" value="[^"]*" />|<string name="ThemeSet" value="dll-arcade" />|' "\$cfg"
  else sed -i 's|</config>|<string name="ThemeSet" value="dll-arcade" />\n</config>|' "\$cfg"; fi
fi
REMOTE
echo "==> Installed $DEST"
