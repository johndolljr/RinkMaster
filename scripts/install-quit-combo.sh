#!/usr/bin/env bash
# Installs (or removes) the SELECT+START quit combo for standalone emulators (Stella, AdvanceMAME) on a cabinet.
#
# Usage:
#   scripts/install-quit-combo.sh USER@HOST            # install and start (also at boot)
#   scripts/install-quit-combo.sh USER@HOST --revert   # stop and remove it
#   scripts/install-quit-combo.sh USER@HOST --hold 2.0 # seconds to hold the two buttons (default 1.5)
#
# RetroArch games already quit with SELECT+START; standalone emulators have no gamepad quit, so with only arcade controls
# there is no way out. Needs key-based SSH and passwordless sudo. The code comes from service/rinkmasterd (service/install.sh).
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -eq 0 ]]; then sed -n '2,11p' "$0"; exit 0; fi
TARGET="$1"; shift
REVERT=0; HOLD=1.5
while [[ $# -gt 0 ]]; do
  case "$1" in
    --revert) REVERT=1; shift ;;
    --hold) HOLD="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$TARGET")

if [[ $REVERT -eq 1 ]]; then
  "${SSH[@]}" "sudo bash -c 'systemctl disable --now quit-combo.service 2>/dev/null; rm -f /etc/systemd/system/quit-combo.service; systemctl daemon-reload'"
  echo "==> Removed the quit combo from $TARGET"
  exit 0
fi
"$HERE/service/install.sh" "$TARGET" --run-user pi | grep -E "OK from|rror" || true
"${SSH[@]}" "sudo bash -s" <<REMOTE
set -euo pipefail
cat > /etc/systemd/system/quit-combo.service <<UNIT
[Unit]
Description=Hold SELECT+START to quit standalone emulators

[Service]
WorkingDirectory=/opt/rinkmaster
ExecStart=/usr/bin/python3 -m rinkmasterd.quitcombo --hold $HOLD
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable quit-combo.service >/dev/null 2>&1
systemctl restart quit-combo.service
sleep 2
systemctl is-active quit-combo.service
journalctl -u quit-combo --no-pager -n 1 | tail -1 | cut -c1-160
REMOTE
echo "==> Installed on $TARGET: hold SELECT+START for $HOLD s to quit Stella / AdvanceMAME"
