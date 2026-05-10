#!/usr/bin/env bash
# Tests for js_escape — escapes a value for safe interpolation inside
# a JavaScript double-quoted string literal. Backslash gets doubled
# first, then double-quote gets backslashed.

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_function js_escape

test_case "js_escape: empty string → empty"
assert_eq "" "$(js_escape "")"

test_case "js_escape: plain alphanumeric pass through"
assert_eq "frigate-ui-theme" "$(js_escape "frigate-ui-theme")"

test_case "js_escape: double-quote gets backslashed"
assert_eq 'hello \"world\"' "$(js_escape 'hello "world"')"

test_case "js_escape: single backslash gets doubled"
assert_eq 'a\\b' "$(js_escape 'a\b')"

test_case "js_escape: backslash before quote — backslash escaped first"
# Input:  a\"b  (backslash, then quote)
# Step 1 (escape \): a\\"b
# Step 2 (escape "): a\\\"b
assert_eq 'a\\\"b' "$(js_escape 'a\"b')"

test_case "js_escape: URL with no special chars"
assert_eq "http://192.168.3.92:30059/?Birdseye" \
  "$(js_escape "http://192.168.3.92:30059/?Birdseye")"

test_case "js_escape: round-trips into a JS string literal"
# Confirm the output, when wrapped in "...", parses as a JS string
# whose value matches the original input. Best test of correctness.
input='He said "go" \ now'
escaped=$(js_escape "$input")
# Use python to decode "${escaped}" as a JS-style double-quoted string
# with backslash escapes. Python's JSON parser handles the same set
# (\\ → \, \" → "), so we can re-decode and compare.
decoded=$(python3 -c "import json,sys; print(json.loads(sys.stdin.read()), end='')" <<<"\"$escaped\"")
assert_eq "$input" "$decoded"

trap _summary EXIT
