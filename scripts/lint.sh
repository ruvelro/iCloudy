#!/usr/bin/env bash
# Lints Sources/ and Tests/ with swift-format (it ships with the toolchain) and the committed .swift-format.
#
# swift-format reports two kinds of findings. The rules (UseShorthandTypeNames, NoBlockComments,
# FileScopedDeclarationPrivacy…) are the ones enabled in .swift-format, all of which the code passes today: any finding
# there fails this script. The pretty-printer's layout findings (Indentation, AddLines, RemoveLine, Spacing,
# TrailingComma, TrailingWhitespace) would mean reformatting the whole codebase, whose style is denser than
# swift-format's; they are counted and printed, and never fail.
#
#     bash scripts/lint.sh            # summary, and the rule findings in full
#     bash scripts/lint.sh --layout   # also every layout finding
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v swift-format >/dev/null 2>&1; then format=(swift-format)
else format=(xcrun swift-format); fi
"${format[@]}" --version

output="$(mktemp)"
trap 'rm -f "$output"' EXIT
# swift-format exits non-zero whenever it prints a finding; what counts is decided below.
"${format[@]}" lint --configuration .swift-format --recursive --parallel --no-color-diagnostics Sources Tests >"$output" 2>&1 || true

layout='\[(Indentation|AddLines|RemoveLine|Spacing|TrailingComma|TrailingWhitespace|LineLength)\]'
if grep -E ': error: ' "$output" | grep -vqE "$layout"; then
    echo "swift-format could not read a file:" >&2
    grep -E ': error: ' "$output" >&2
    exit 1
fi
rules="$(grep -E ': (warning|error): \[' "$output" | grep -vE "$layout" || true)"
layout_count="$(grep -cE "$layout" "$output" || true)"

echo "Layout findings (informational, not enforced): ${layout_count}"
grep -oE "$layout" "$output" | sort | uniq -c | sort -rn || true
if [[ "${1:-}" == "--layout" ]]; then grep -E "$layout" "$output" || true; fi

if [[ -n "$rules" ]]; then
    echo
    echo "Rule findings ($(printf '%s\n' "$rules" | wc -l | tr -d ' ')), which fail the lint:" >&2
    printf '%s\n' "$rules" >&2
    exit 1
fi
echo "No rule findings."
