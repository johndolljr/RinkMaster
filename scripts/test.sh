#!/usr/bin/env bash
# Runs the unit tests and enforces the coverage minimums (85% region, 80% line, 90% functions;
# override with MIN_REGION_COVERAGE / MIN_LINE_COVERAGE / MIN_FUNCTION_COVERAGE).
#
# Usage:
#   scripts/test.sh              # all tests + coverage report and gate
#   scripts/test.sh <filter>     # only tests matching the filter (no coverage gate)
#   scripts/test.sh --last       # reprint the last coverage summary without re-running
#
# The coverage report is persisted at .build/coverage/report.txt.
set -euo pipefail
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then sed -n '2,11p' "$0"; exit 0; fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
source "$HERE/lib.sh"
SPM_EXECUTABLE="$(_detect_spm_executable)"
if [[ "${1:-}" == "--last" ]]; then
  print_coverage_summary "$(spm_package_name)"
elif [[ $# -gt 0 ]]; then
  log "Running tests matching filter: $*"
  (cd "$REPO_ROOT" && swift test --filter "$1")
else
  run_spm_tests_with_coverage
fi
