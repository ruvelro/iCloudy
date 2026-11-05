#!/usr/bin/env bash
# Exports the coverage of the last `swift test --enable-code-coverage` run as LCOV and prints it per folder.
#
#     swift test --enable-code-coverage [--parallel]
#     scripts/ci/coverage.sh [coverage.lcov]
#
# Only the app's own sources count: the tests, the build folder and the test bootstrap are left out.
set -euo pipefail
cd "$(dirname "$0")/../.."
output="${1:-coverage.lcov}"

bin="$(swift build --show-bin-path)"
profile="$bin/codecov/default.profdata"
bundle="$(ls -d "$bin"/*.xctest | head -1)"
executable="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
if [[ ! -f "$profile" ]]; then echo "No coverage data at $profile: run swift test --enable-code-coverage first." >&2; exit 1; fi

xcrun llvm-cov export -format=lcov -instr-profile "$profile" "$executable" \
    -ignore-filename-regex='(/\.build/|/Tests/)' >"$output"
python3 scripts/ci/coverage_summary.py "$output"
