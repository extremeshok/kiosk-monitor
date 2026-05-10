#!/usr/bin/env bash
# Integration tests — invoke kiosk-monitor.sh as a subprocess and
# inspect its stdout/stderr/exit. Covers the trivial dispatch paths
# (--version, --help) plus --doctor against a minimal fixture config.

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ---- --version --------------------------------------------------------

test_case "--version exits 0"
run_kiosk --version
assert_eq "0" "$LAST_RC"

test_case "--version prints a SemVer-shaped string"
run_kiosk --version
assert_match '^[0-9]+\.[0-9]+\.[0-9]+$' "$LAST_STDOUT"

test_case "--version matches SCRIPT_VERSION in source"
expected=$(awk -F'"' '/^SCRIPT_VERSION=/{print $2; exit}' "$SCRIPT")
run_kiosk --version
assert_eq "$expected" "$LAST_STDOUT"

# ---- --help -----------------------------------------------------------

test_case "--help exits 0"
run_kiosk --help
assert_eq "0" "$LAST_RC"

test_case "--help mentions --install"
run_kiosk --help
assert_match -- "--install" "$LAST_STDOUT"

test_case "--help mentions --doctor"
run_kiosk --help
assert_match -- "--doctor" "$LAST_STDOUT"

# ---- --doctor ---------------------------------------------------------

test_case "--doctor against minimal config completes (errors counted, summary printed)"
run_kiosk --config "$FIXTURES_DIR/minimal.conf" --doctor
# We don't assert exit=0 because doctor will likely flag missing
# packages on a CI/dev box (chromium, grim, etc.). What we assert is
# that doctor ran end to end — the summary line is the marker.
assert_match 'Doctor summary: [0-9]+ error\(s\), [0-9]+ warning\(s\)' "$LAST_STDOUT"

test_case "--doctor reports the version it tested"
run_kiosk --config "$FIXTURES_DIR/minimal.conf" --doctor
expected=$(awk -F'"' '/^SCRIPT_VERSION=/{print $2; exit}' "$SCRIPT")
assert_match "Version: $expected" "$LAST_STDOUT"

test_case "--doctor exercises every check (looks for distinctive markers)"
run_kiosk --config "$FIXTURES_DIR/minimal.conf" --doctor
# config-file check, command check, desktop-user check, output check
assert_match 'config file' "$LAST_STDOUT"
assert_match 'found command|missing command' "$LAST_STDOUT"
assert_match 'desktop user|GUI_USER' "$LAST_STDOUT"

# ---- unknown subcommand -----------------------------------------------

test_case "unknown subcommand prints usage and exits non-zero"
run_kiosk --not-a-real-subcommand
assert_ne "0" "$LAST_RC"

trap _summary EXIT
