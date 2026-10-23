#!/usr/bin/env bash
# Installs (or upgrades) the rinkmasterd service on a RetroPie cabinet over SSH.
#
# Usage:
#   service/install.sh USER@HOST [--port 8472] [--run-user pi] [--roms /home/pi/RetroPie/roms]
#
# Copies service/rinkmasterd to /opt/rinkmaster, writes /etc/systemd/system/rinkmasterd.service
# (runs as --run-user), enables it so it starts at boot, restarts it, and checks /health from the
# cabinet and from this machine. Needs key-based SSH and passwordless sudo for USER on HOST.
# Safe to run again: it upgrades the code in place.
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -eq 0 ]]; then sed -n '2,12p' "$0"; exit 0; fi

TARGET="$1"; shift
PORT=8472; RUN_USER=pi; ROMS=/home/pi/RetroPie/roms
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --run-user) RUN_USER="$2"; shift 2 ;;
    --roms) ROMS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
HOST="${TARGET#*@}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$TARGET")

echo "==> Copying rinkmasterd to $TARGET"
"${SSH[@]}" "mkdir -p /tmp/rinkmasterd-install/rinkmasterd"
rsync -rlt --delete --exclude '__pycache__' -e "ssh -o BatchMode=yes" "$HERE/rinkmasterd/" "$TARGET:/tmp/rinkmasterd-install/rinkmasterd/"

echo "==> Installing to /opt/rinkmaster and configuring systemd"
"${SSH[@]}" "sudo bash -s" <<REMOTE
set -euo pipefail
mkdir -p /opt/rinkmaster
rsync -rlt --delete --exclude '__pycache__' /tmp/rinkmasterd-install/rinkmasterd/ /opt/rinkmaster/rinkmasterd/
chown -R root:root /opt/rinkmaster
rm -rf /tmp/rinkmasterd-install
cat > /etc/systemd/system/rinkmasterd.service <<UNIT
[Unit]
Description=RinkMaster cabinet service
After=network-online.target
Wants=network-online.target

[Service]
User=$RUN_USER
WorkingDirectory=/opt/rinkmaster
ExecStart=/usr/bin/python3 -m rinkmasterd --port $PORT --roms $ROMS --configs /opt/retropie/configs
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable rinkmasterd.service >/dev/null 2>&1
systemctl restart rinkmasterd.service
REMOTE

echo "==> Checking /health"
for i in 1 2 3 4 5 6 7 8; do
  if out=$(curl -s -m 3 "http://$HOST:$PORT/health"); [[ "$out" == *'"ok": true'* ]]; then
    echo "OK from this machine: $out"; exit 0
  fi
  sleep 1
done
echo "Service did not answer on $HOST:$PORT; check: ssh $TARGET 'systemctl status rinkmasterd; journalctl -u rinkmasterd -n 30'" >&2
exit 1
