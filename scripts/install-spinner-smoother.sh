#!/usr/bin/env bash
# Installs (or removes) the spinner smoother on a cabinet: a service that re-sends the spinner's movement as an even stream.
#
# Usage:
#   scripts/install-spinner-smoother.sh USER@HOST            # install, start now and at boot; spinner games use the smoothed mouse
#   scripts/install-spinner-smoother.sh USER@HOST --revert   # stop and disable it; spinner games go back to the real spinner
#   scripts/install-spinner-smoother.sh USER@HOST --name LINKFLY --tau-ms 14   # which device to smooth, and how much
#   scripts/install-spinner-smoother.sh USER@HOST --system-cfg /opt/retropie/configs/mame-libretro/retroarch.cfg
#       # a cabinet where every game uses the spinner (arcade2): set `input_player1_mouse_index` once in that RetroArch
#       # config instead of editing each game's .zip.cfg. --index N is the smoothed spinner's mouse number (default 3).
#
# The smoothed spinner is a new virtual mouse that RetroArch numbers after the real ones (3 on both cabinets). By default the
# per-game `<rom>.zip.cfg` files in the mame-libretro folder that say `input_player1_mouse_index = 0` (the spinner) are changed
# to 3, and back to 0 on --revert. Needs key-based SSH and passwordless sudo. The service code comes from service/rinkmasterd.
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -eq 0 ]]; then sed -n '2,14p' "$0"; exit 0; fi
TARGET="$1"; shift
REVERT=0; NAME=LINKFLY; TAU=14; ROMS=/home/pi/RetroPie/roms/mame-libretro; INDEX=3; SYSCFG=""   # xarcade 3; arcade2 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --revert) REVERT=1; shift ;;
    --name) NAME="$2"; shift 2 ;;
    --tau-ms) TAU="$2"; shift 2 ;;
    --roms) ROMS="$2"; shift 2 ;;
    --index) INDEX="$2"; shift 2 ;;
    --system-cfg) SYSCFG="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$TARGET")

if [[ $REVERT -eq 1 ]]; then
  echo "==> Removing the smoother from $TARGET"
  "${SSH[@]}" "sudo bash -s" <<REMOTE
systemctl disable --now spinner-smooth.service 2>/dev/null || true
rm -f /etc/systemd/system/spinner-smooth.service
systemctl daemon-reload
for f in "$ROMS"/*.zip.cfg; do [ -e "\$f" ] && sed -i 's/^input_player1_mouse_index = $INDEX\$/input_player1_mouse_index = 0/' "\$f"; done
if [ -n "$SYSCFG" ] && [ -e "$SYSCFG" ]; then sed -i '/^# spinner smoother\$/,/^input_player1_mouse_index = .*\$/d' "$SYSCFG"; sync; fi
echo "games point at the real spinner again"
REMOTE
  exit 0
fi

echo "==> Deploying the service code (includes the smoother)"
"$HERE/service/install.sh" "$TARGET" --run-user pi | grep -E "OK from|rror" || true
echo "==> Installing spinner-smooth.service on $TARGET"
"${SSH[@]}" "sudo bash -s" <<REMOTE
set -euo pipefail
cat > /etc/systemd/system/spinner-smooth.service <<UNIT
[Unit]
Description=Spinner smoother (even movement for the arcade spinner)
After=systemd-udev-settle.service

[Service]
WorkingDirectory=/opt/rinkmaster
ExecStart=/usr/bin/python3 -m rinkmasterd.spinner --name "$NAME" --tau-ms $TAU
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable spinner-smooth.service >/dev/null 2>&1
systemctl restart spinner-smooth.service
sleep 2
systemctl is-active spinner-smooth.service
grep -c 'Smoothed Spinner' /proc/bus/input/devices | sed 's/^/virtual spinner devices: /'
if [ -n "$SYSCFG" ]; then
  cp -p "$SYSCFG" "$SYSCFG.bak-spinner"
  if ! grep -q '^# spinner smoother\$' "$SYSCFG"; then
    python3 - "$SYSCFG" "$INDEX" <<'PY'
import sys
path, idx = sys.argv[1], sys.argv[2]
text = open(path).read()
add = "# spinner smoother\ninput_player1_mouse_index = %s\n" % idx
marker = "input_remapping_directory"
open(path, "w").write(text.replace(marker, add + marker, 1) if marker in text else add + text)
PY
  fi
  sync
  echo "every game now uses the smoothed spinner (mouse $INDEX) via $SYSCFG"
else
  n=0
  for f in "$ROMS"/*.zip.cfg; do
    if [ -e "\$f" ] && grep -q '^input_player1_mouse_index = 0\$' "\$f"; then sed -i 's/^input_player1_mouse_index = 0\$/input_player1_mouse_index = $INDEX/' "\$f"; n=\$((n+1)); fi
  done
  echo "spinner games switched to the smoothed spinner: \$n"
fi
REMOTE
