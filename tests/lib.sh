#!/usr/bin/env bash
# tests/lib.sh — shared helpers for kiosk-monitor's bash test harness.
#
# Two execution modes are supported by the test files that source this:
#
#   1. Pure-function tests: extract one or more functions from
#      kiosk-monitor.sh by name (via sed) and source them in the test
#      shell. The script's main flow never runs, so we can call
#      individual helpers in isolation. Use load_function for this.
#
#   2. Integration tests: invoke kiosk-monitor.sh as a subprocess with
#      specific args and inspect stdout/stderr/exit. Use run_kiosk for
#      this.
#
# Either way, the test file's exit code is what matters: 0 = all
# assertions passed, non-zero = first failure aborts. The runner at
# tests/run.sh aggregates per-file results.

set -Eeuo pipefail

# Resolve script under test relative to the test file's location.
TESTS_DIR=${TESTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
SCRIPT=${SCRIPT:-"$TESTS_DIR/../kiosk-monitor.sh"}
FIXTURES_DIR=${FIXTURES_DIR:-"$TESTS_DIR/fixtures"}

if [ ! -f "$SCRIPT" ]; then
  printf 'lib.sh: cannot find kiosk-monitor.sh at %s\n' "$SCRIPT" >&2
  exit 2
fi

# Pull a single function definition (function NAME() { … }) out of the
# script and eval it in the current shell. Multiple calls accumulate.
# Useful for unit-testing pure helpers without running the main flow.
load_function() {
  local name=$1 def
  def=$(awk -v fn="$name" '
    $0 ~ "^"fn"\\(\\) \\{" { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { exit }
  ' "$SCRIPT")
  if [ -z "$def" ]; then
    printf 'load_function: %q not found in %s\n' "$name" "$SCRIPT" >&2
    return 1
  fi
  eval "$def"
}

# Convenience: load several functions in one call.
load_functions() {
  local fn
  for fn in "$@"; do load_function "$fn"; done
}

# Run kiosk-monitor.sh as a subprocess. Returns whatever the script
# returns; captures stdout in $LAST_STDOUT, stderr in $LAST_STDERR,
# exit code in $LAST_RC. The function itself always returns 0 so the
# caller can assert against the captured fields without `set -e`
# tripping on a non-zero exit.
LAST_STDOUT=""; LAST_STDERR=""; LAST_RC=0
run_kiosk() {
  local stdout_file stderr_file
  stdout_file=$(mktemp); stderr_file=$(mktemp)
  set +e
  bash "$SCRIPT" "$@" >"$stdout_file" 2>"$stderr_file"
  LAST_RC=$?
  set -e
  LAST_STDOUT=$(cat "$stdout_file"); LAST_STDERR=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"
  return 0
}

# Assertion primitives. Each prints the failure context and aborts the
# test file; the runner sees the non-zero exit and tallies a failure.
_TEST_NAME=""
_TEST_PASSED=0
_TEST_FAILED=0
test_case() { _TEST_NAME=$1; }

_fail() {
  _TEST_FAILED=$((_TEST_FAILED + 1))
  printf '  FAIL: %s\n' "$_TEST_NAME" >&2
  printf '    %s\n' "$@" >&2
  exit 1
}

_pass() {
  _TEST_PASSED=$((_TEST_PASSED + 1))
  printf '  PASS: %s\n' "$_TEST_NAME"
}

assert_eq() {
  local expected=$1 actual=$2
  if [ "$expected" = "$actual" ]; then
    _pass
  else
    _fail "expected: $(printf '%q' "$expected")" "actual:   $(printf '%q' "$actual")"
  fi
}

assert_ne() {
  local unexpected=$1 actual=$2
  if [ "$unexpected" != "$actual" ]; then
    _pass
  else
    _fail "expected anything but: $(printf '%q' "$unexpected")"
  fi
}

assert_match() {
  local pattern=$1 string=$2
  if [[ "$string" =~ $pattern ]]; then
    _pass
  else
    _fail "pattern: $pattern" "string:  $(printf '%q' "$string")"
  fi
}

assert_no_match() {
  local pattern=$1 string=$2
  if [[ "$string" =~ $pattern ]]; then
    _fail "did not expect to match: $pattern" "string:  $(printf '%q' "$string")"
  else
    _pass
  fi
}

assert_succeeds() {
  local desc=$1; shift
  if "$@"; then
    _pass
  else
    _fail "expected success: $desc" "exit code: $?"
  fi
}

assert_fails() {
  local desc=$1; shift
  set +e
  "$@"
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    _pass
  else
    _fail "expected non-zero exit: $desc"
  fi
}

# Print summary at end-of-file (called from each test via trap below).
_summary() {
  printf '\n%s: %d passed, %d failed\n' "$(basename "${BASH_SOURCE[1]:-tests}" .sh)" "$_TEST_PASSED" "$_TEST_FAILED"
  [ "$_TEST_FAILED" -eq 0 ]
}
