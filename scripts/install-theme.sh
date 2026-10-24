#!/usr/bin/env bash
# Installs an arcade theme (themes/dll-arcade for EmulationStation, themes/rink for Attract-Mode) on a cabinet.
#
# Usage:
#   scripts/install-theme.sh USER@HOST [--frontend es|attract] [--theme NAME] [--activate]
#
# If --frontend is omitted, it auto-detects based on /opt/retropie/configs/all/attractmode or emulationstation.
# Defaults:
#   EmulationStation: theme "dll-arcade" -> /opt/retropie/configs/all/emulationstation/themes/dll-arcade
#   Attract-Mode:     theme "rink"       -> /opt/retropie/configs/all/attractmode/layouts/rink
# --activate configures the installed theme as active in es_settings.cfg or attract.cfg.
# Needs key-based SSH and passwordless sudo for USER on HOST.
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -eq 0 ]]; then sed -n '2,12p' "$0"; exit 0; fi

TARGET="$1"; shift
FRONTEND=""
THEME=""
ACTIVATE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --frontend) FRONTEND="$2"; shift 2 ;;
    --theme) THEME="$2"; shift 2 ;;
    --activate) ACTIVATE=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$TARGET")

if [[ -z "$FRONTEND" ]]; then
  echo "==> Detecting frontend on $TARGET..."
  if "${SSH[@]}" "[ -d /opt/retropie/configs/all/attractmode ]"; then
    FRONTEND="attract"
  else
    FRONTEND="es"
  fi
fi

if [[ "$FRONTEND" == "attract" || "$FRONTEND" == "attract-mode" ]]; then
  THEME="${THEME:-rink}"
  SRC="$HERE/themes/$THEME"
  [[ -d "$SRC" ]] || { echo "Error: theme directory $SRC not found" >&2; exit 1; }
  DEST="/opt/retropie/configs/all/attractmode/layouts/$THEME"
  echo "==> Installing Attract-Mode layout '$THEME' on $TARGET..."
  "${SSH[@]}" "mkdir -p /tmp/attract-theme"
  rsync -rlt --delete -e "ssh -o BatchMode=yes" "$SRC/" "$TARGET:/tmp/attract-theme/"
  "${SSH[@]}" "bash -s" <<REMOTE
set -euo pipefail
mkdir -p "$DEST"
rsync -rlt --delete /tmp/attract-theme/ "$DEST/"
rm -rf /tmp/attract-theme
if [[ $ACTIVATE -eq 1 ]]; then
  cfg=/opt/retropie/configs/all/attractmode/attract.cfg
  if [ -f "\$cfg" ]; then
    cp -p "\$cfg" "\$cfg.bak-theme"
    sed -i 's/^[[:space:]]*layout[[:space:]]\+[^\r\n]*/\tlayout               $THEME/' "\$cfg"
  fi
fi
REMOTE
  echo "==> Installed layout at $DEST"
else
  THEME="${THEME:-dll-arcade}"
  SRC="$HERE/themes/$THEME"
  [[ -d "$SRC" ]] || { echo "Error: theme directory $SRC not found" >&2; exit 1; }
  DEST="/opt/retropie/configs/all/emulationstation/themes/$THEME"
  if [[ -f "$SRC/theme.xml" ]]; then
    python3 -c "import sys, xml.dom.minidom as m; m.parse(sys.argv[1])" "$SRC/theme.xml"
  fi
  echo "==> Installing EmulationStation theme '$THEME' on $TARGET..."
  "${SSH[@]}" "mkdir -p /tmp/es-theme"
  rsync -rlt --delete -e "ssh -o BatchMode=yes" "$SRC/" "$TARGET:/tmp/es-theme/"
  "${SSH[@]}" "sudo bash -s" <<REMOTE
set -euo pipefail
owner=\$(stat -c %U /opt/retropie/configs/all/emulationstation)
mkdir -p "$DEST"
rsync -rlt --delete /tmp/es-theme/ "$DEST/"
chown -R "\$owner:\$owner" /opt/retropie/configs/all/emulationstation/themes
rm -rf /tmp/es-theme
if [[ $ACTIVATE -eq 1 ]]; then
  cfg=/opt/retropie/configs/all/emulationstation/es_settings.cfg
  if [ -f "\$cfg" ]; then
    cp -p "\$cfg" "\$cfg.bak-theme"
    if grep -q 'name="ThemeSet"' "\$cfg"; then
      sed -i 's|<string name="ThemeSet" value="[^"]*" />|<string name="ThemeSet" value="$THEME" />|' "\$cfg"
    else
      sed -i 's|</config>|<string name="ThemeSet" value="$THEME" />\n</config>|' "\$cfg"
    fi
  else
    mkdir -p "\$(dirname "\$cfg")"
    echo '<config><string name="ThemeSet" value="$THEME" /></config>' > "\$cfg"
    chown "\$owner:\$owner" "\$cfg"
  fi
fi
REMOTE
  echo "==> Installed theme at $DEST"
fi
