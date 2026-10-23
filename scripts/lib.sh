#!/usr/bin/env bash
# Shared helpers for RinkMaster build/run/test/install scripts.
# Self-contained for open-source use.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

_detect_spm_executable() {
    if [[ -n "${SCHEME:-}" ]]; then
        echo "$SCHEME"
        return
    fi
    local name
    name="$(cd "$REPO_ROOT" && swift package describe --type json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for product in data.get("products", []):
    product_type = product.get("type")
    if product_type == "executable" or (isinstance(product_type, dict) and "executable" in product_type):
        print(product["name"])
        break
')"
    echo "${name:-RinkMaster}"
}

detect_build_target() {
    BUILD_MODE="spm"
    SPM_EXECUTABLE="$(_detect_spm_executable)"
}

spm_configuration() {
    case "$1" in
        Debug|debug) echo debug ;;
        Release|release) echo release ;;
        *) die "Unknown configuration '$1' (expected Debug or Release)" ;;
    esac
}

spm_bin_path() {
    local configuration="$1"
    echo "$(cd "$REPO_ROOT" && swift build -c "$configuration" --show-bin-path)/${SPM_EXECUTABLE:-RinkMaster}"
}

spm_package_name() {
    (cd "$REPO_ROOT" && swift package describe --type json 2>/dev/null | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("name", "RinkMaster"))
except ValueError:
    print("RinkMaster")
')
}

COVERAGE_DIR="$REPO_ROOT/.build/coverage"
COVERAGE_REPORT_FILE="$COVERAGE_DIR/report.txt"

print_coverage_summary() {
    local package_name="${1:-$(spm_package_name)}"
    [[ -f "$COVERAGE_REPORT_FILE" ]] || die "No coverage report found at $COVERAGE_REPORT_FILE (run test.sh first)."

    log "Coverage summary ($package_name, from $(date -r "$COVERAGE_REPORT_FILE" '+%Y-%m-%d %H:%M:%S'))"
    echo
    awk '/^Filename/ || /^TOTAL/ || /^-----/' "$COVERAGE_REPORT_FILE"

    local region_cov func_cov line_cov
    region_cov="$(awk '/^TOTAL/ { gsub("%","",$4); print $4 }' "$COVERAGE_REPORT_FILE")"
    func_cov="$(awk '/^TOTAL/ { gsub("%","",$7); print $7 }' "$COVERAGE_REPORT_FILE")"
    line_cov="$(awk '/^TOTAL/ { gsub("%","",$10); print $10 }' "$COVERAGE_REPORT_FILE")"
    if [[ -z "$region_cov" || -z "$func_cov" || -z "$line_cov" ]]; then
        echo "warn: could not parse coverage totals from report" >&2
        return 0
    fi

    local min_region="${MIN_REGION_COVERAGE:-85}"
    local min_line="${MIN_LINE_COVERAGE:-80}"
    local min_functions="${MIN_FUNCTION_COVERAGE:-90}"

    echo
    echo "$package_name coverage: ${region_cov}% region (min ${min_region}%), ${line_cov}% line (min ${min_line}%), ${func_cov}% functions (min ${min_functions}%)"

    local failed=0
    (( $(echo "$region_cov < $min_region" | bc -l) )) && { echo "error: region coverage ${region_cov}% is below the required ${min_region}%" >&2; failed=1; }
    (( $(echo "$line_cov < $min_line" | bc -l) )) && { echo "error: line coverage ${line_cov}% is below the required ${min_line}%" >&2; failed=1; }
    (( $(echo "$func_cov < $min_functions" | bc -l) )) && { echo "error: executed-function coverage ${func_cov}% is below the required ${min_functions}%" >&2; failed=1; }
    [[ "$failed" -eq 0 ]] || exit 1
}

spm_write_app_info_plist() {
    local dest_plist="$1"
    local icon_name="$2"
    local executable="${SPM_EXECUTABLE:-RinkMaster}"
    local source_plist="$REPO_ROOT/Sources/$executable/Info.plist"
    local bundle_id="${RINKMASTER_BUNDLE_ID:-com.ragingcoders.$executable}"
    python3 - "$source_plist" "$dest_plist" "$executable" "$bundle_id" "$icon_name" <<'PYEOF'
import plistlib
import sys

source_path, dest_path, executable, bundle_id, icon_name = sys.argv[1:6]

data = {}
try:
    with open(source_path, "rb") as f:
        data = plistlib.load(f)
except (FileNotFoundError, IsADirectoryError):
    pass

data["CFBundleExecutable"] = executable
data["CFBundleIdentifier"] = bundle_id
data["CFBundleName"] = executable
data["CFBundlePackageType"] = "APPL"
data.setdefault("CFBundleShortVersionString", "1.0")
data.setdefault("CFBundleVersion", "1")
data["NSHighResolutionCapable"] = True
if icon_name:
    data["CFBundleIconFile"] = icon_name

with open(dest_path, "wb") as f:
    plistlib.dump(data, f)
PYEOF
}

run_spm_tests_with_coverage() {
    local package_name
    package_name="$(spm_package_name)"
    [[ -n "$package_name" ]] || die "Could not determine package name via swift package describe."

    log "Running full test suite with coverage"
    (cd "$REPO_ROOT" && swift test --enable-code-coverage)

    local bin_path test_binary profdata
    bin_path="$(cd "$REPO_ROOT" && swift build --show-bin-path)"
    profdata="$bin_path/codecov/default.profdata"
    test_binary="$bin_path/${package_name}PackageTests.xctest/Contents/MacOS/${package_name}PackageTests"
    if [[ ! -f "$test_binary" ]]; then
        local bundle
        bundle="$(find "$bin_path" -maxdepth 1 -name '*.xctest' -type d | sort | head -1)"
        [[ -n "$bundle" ]] || die "No .xctest bundle found in $bin_path after swift test."
        test_binary="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
    fi
    [[ -f "$test_binary" ]] || die "Test binary not found at $test_binary."

    mkdir -p "$COVERAGE_DIR"

    echo
    log "Full coverage report ($package_name)"
    xcrun llvm-cov report "$test_binary" \
        -instr-profile="$profdata" \
        --ignore-filename-regex="/Tests/|/Sources/${SPM_EXECUTABLE}/|/\.build/|DerivedSources" \
        | tee "$COVERAGE_REPORT_FILE"

    echo
    print_coverage_summary "$package_name"
}
