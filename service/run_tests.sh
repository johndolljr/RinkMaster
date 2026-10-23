#!/usr/bin/env bash
# Runs the rinkmasterd unit tests (stdlib unittest).
#
# Usage:
#   service/run_tests.sh             # run locally (this Mac's python3)
#   service/run_tests.sh --coverage  # run with coverage (needs `python3 -m venv`; installs coverage into service/.venv), min 85%
#   service/run_tests.sh --pi HOST   # copy the service to HOST (e.g. pi@cabinet.lan) and run the tests there,
#                                    # on the Pi's Python 3.9
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then sed -n '2,9p' "$0"; exit 0; fi
cd "$(dirname "${BASH_SOURCE[0]}")"
if [[ "${1:-}" == "--coverage" ]]; then
  [[ -x .venv/bin/python ]] || { python3 -m venv .venv && .venv/bin/pip install -q coverage; }
  .venv/bin/python -m coverage run --source=rinkmasterd -m unittest discover -s tests -t .
  .venv/bin/python -m coverage report -m --fail-under=85
  exit
fi
if [[ "${1:-}" == "--pi" ]]; then
  host="${2:?usage: run_tests.sh --pi user@host}"
  rsync -rlt --delete --exclude '__pycache__' -e "ssh -o BatchMode=yes" ./ "$host:/tmp/rinkmasterd-test/"
  ssh -o BatchMode=yes "$host" 'cd /tmp/rinkmasterd-test && python3 -m unittest discover -s tests -t . -v 2>&1 | tail -5; rm -rf /tmp/rinkmasterd-test'
else
  python3 -m unittest discover -s tests -t . "${@}"
fi
