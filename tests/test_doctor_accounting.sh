#!/usr/bin/env bash
# Tests for v6.9.3's doctor accounting fix.
#
# Before v6.9.3 the doctor's runtime-config check called
# validate_runtime_config and printed [ok]/[error] based on the exit
# code only. Any "Config warning:" / "Config error:" lines the
# validator emitted to stderr went straight to the terminal but never
# touched the doctor's $warnings/$errors counters, so the final
# `Doctor summary: N error(s), M warning(s)` line was wrong. Issue
# #1's reporter surfaced this on v6.9.2: their `--doctor` printed
# two Config warning lines (correct — the v6.9.0 MODE=vlc + HTTP-URL
# guard firing) but the summary said `0 error(s), 0 warning(s)`.
#
# v6.9.3 routes validator lines through doctor_warn/doctor_error so
# the summary reflects what's printed.

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ---- the misconfig the reporter hit ---------------------------------

test_case "vlc+http misconfig: doctor prints two [warn] lines"
run_kiosk --config "$FIXTURES_DIR/vlc-http-misconfig.conf" --doctor
# Each instance gets its own warning; both should show up as
# explicit "[warn]" lines from doctor_warn (not just plain stderr).
warn_lines=$(printf '%s\n' "$LAST_STDOUT" | grep -c '^\[warn\] .*looks like an HTTP web page' || true)
assert_eq "2" "$warn_lines"

# Helper: pull the warnings / errors count out of the summary line.
# Format is `Doctor summary: N error(s), M warning(s)`. Echoes "N M".
_parse_summary() {
  local s
  s=$(printf '%s\n' "$1" | grep '^Doctor summary:' | tail -1)
  printf '%s\n' "$s" | sed -E 's/^Doctor summary: ([0-9]+) error\(s\), ([0-9]+) warning\(s\).*/\1 \2/'
}

test_case "vlc+http misconfig: doctor summary counts >= 2 warnings (was 0 in v6.9.2)"
run_kiosk --config "$FIXTURES_DIR/vlc-http-misconfig.conf" --doctor
counts=$(_parse_summary "$LAST_STDOUT")
warnings=${counts##* }
[ "${warnings:-0}" -ge 2 ] || _fail "expected >=2 warnings, got summary='$(printf '%s' "$LAST_STDOUT" | grep '^Doctor summary:')'"
_pass

test_case "vlc+http misconfig: warning mentions go2rtc RTSP recipe"
run_kiosk --config "$FIXTURES_DIR/vlc-http-misconfig.conf" --doctor
assert_match 'rtsp://<frigate>:8554/birdseye' "$LAST_STDOUT"

test_case "valid config: doctor summary line has parseable counts"
run_kiosk --config "$FIXTURES_DIR/minimal.conf" --doctor
counts=$(_parse_summary "$LAST_STDOUT")
# Both counts must be non-empty integers, regardless of their actual
# values (CI/dev boxes will have missing-chromium errors and similar).
assert_match '^[0-9]+ [0-9]+$' "$counts"

trap _summary EXIT
