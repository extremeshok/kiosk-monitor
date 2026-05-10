#!/usr/bin/env bash
# tests/run.sh — run every test_*.sh in this directory and aggregate
# pass/fail. Exits non-zero if any test file fails. Each test file is
# executed in its own bash subshell so `set -e` failures stop only
# the failing file, not the runner.
#
# Usage:
#   tests/run.sh                 # run all tests
#   tests/run.sh test_url_*.sh   # run a subset (passes globs through)
#   VERBOSE=1 tests/run.sh       # show every test's PASS lines
#
# Exit codes:
#   0 = all test files passed
#   1 = at least one test file failed
#   2 = harness error (e.g. tests/lib.sh missing)

set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$TESTS_DIR"

if [ ! -f lib.sh ]; then
  printf 'tests/run.sh: lib.sh missing\n' >&2
  exit 2
fi

declare -a TEST_FILES
if [ "$#" -gt 0 ]; then
  TEST_FILES=( "$@" )
else
  mapfile -t TEST_FILES < <(ls test_*.sh 2>/dev/null | sort)
fi

if [ "${#TEST_FILES[@]}" -eq 0 ]; then
  printf 'tests/run.sh: no test files matched\n' >&2
  exit 2
fi

VERBOSE=${VERBOSE:-0}

total_files=0
failed_files=0
total_passed=0
total_failed=0
declare -a failed_names=()

printf '=== kiosk-monitor test harness ===\n'
printf 'Script under test: %s\n\n' "$(cd .. && pwd)/kiosk-monitor.sh"

for f in "${TEST_FILES[@]}"; do
  [ -f "$f" ] || { printf 'skip (not found): %s\n' "$f" >&2; continue; }
  total_files=$((total_files + 1))
  printf -- '--- %s ---\n' "$f"
  set +e
  if [ "$VERBOSE" = "1" ]; then
    bash "$f"
  else
    # Capture output; show it only on failure or on the summary line.
    out=$(bash "$f" 2>&1)
  fi
  rc=$?
  set -e
  if [ "$VERBOSE" != "1" ]; then
    # Always show the summary (last line of each test file's output)
    # plus, if it failed, all of its output for diagnostics.
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$out"
    else
      printf '%s\n' "$out" | tail -1
    fi
  fi
  # Tally per-file passed/failed by parsing the summary line.
  summary=$(printf '%s\n' "${out:-}" | grep -E ': [0-9]+ passed, [0-9]+ failed' | tail -1 || true)
  if [ -n "$summary" ]; then
    p=$(printf '%s' "$summary" | awk -F'[ ,:]+' '{for(i=1;i<=NF;i++) if($i=="passed") print $(i-1)}')
    fl=$(printf '%s' "$summary" | awk -F'[ ,:]+' '{for(i=1;i<=NF;i++) if($i=="failed") print $(i-1)}')
    total_passed=$((total_passed + p))
    total_failed=$((total_failed + fl))
  fi
  if [ "$rc" -ne 0 ]; then
    failed_files=$((failed_files + 1))
    failed_names+=( "$f" )
  fi
done

printf '\n=== summary ===\n'
printf 'Files: %d total, %d failed\n' "$total_files" "$failed_files"
printf 'Tests: %d passed, %d failed\n' "$total_passed" "$total_failed"
if [ "$failed_files" -gt 0 ]; then
  printf 'Failed files:\n'
  for n in "${failed_names[@]}"; do printf '  %s\n' "$n"; done
  exit 1
fi
exit 0
