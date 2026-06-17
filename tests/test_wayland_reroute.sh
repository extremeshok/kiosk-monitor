#!/usr/bin/env bash
# Tests for wayland_settle_reroute — the post-launch labwc re-route "settle"
# added so a VLC surface that maps late (HEVC waiting for its first keyframe,
# after the launch-time nudge) still gets routed to its output instead of
# stranding that display on the desktop.
#
# Strategy: load the helper, then mock reload_labwc_window_rules (count calls)
# and sleep (no-op, record interval). Bash resolves function names at call
# time, so the mocks defined here override the real ones inside the helper.
#
# What's covered:
#  - off-Wayland (x11 / unset SESSION_TYPE): no nudges at all
#  - Wayland + single instance: exactly one immediate nudge, no settle loop
#  - Wayland + multi-instance: immediate nudge + WAYLAND_REROUTE_SETTLE_TICKS more
#  - SETTLE_TICKS=0: only the immediate nudge
#  - sleep uses WAYLAND_REROUTE_SETTLE_INTERVAL

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_function wayland_settle_reroute

NUDGES=0
SLEEPS=0
LAST_SLEEP=""
reload_labwc_window_rules() { NUDGES=$((NUDGES + 1)); }
sleep() { SLEEPS=$((SLEEPS + 1)); LAST_SLEEP="$1"; }

reset() { NUDGES=0; SLEEPS=0; LAST_SLEEP=""; }

WAYLAND_REROUTE_SETTLE_TICKS=3
WAYLAND_REROUTE_SETTLE_INTERVAL=4

test_case "off-Wayland (x11): no nudges"
SESSION_TYPE="x11"; INSTANCES=(1 2); reset
wayland_settle_reroute
assert_eq "0" "$NUDGES"

test_case "unset SESSION_TYPE: no nudges"
SESSION_TYPE=""; INSTANCES=(1 2); reset
wayland_settle_reroute
assert_eq "0" "$NUDGES"

test_case "Wayland + single instance: one immediate nudge, no settle loop"
SESSION_TYPE="wayland"; INSTANCES=(1); reset
wayland_settle_reroute
assert_eq "1" "$NUDGES"
assert_eq "0" "$SLEEPS"

test_case "Wayland + 2 instances: immediate nudge + SETTLE_TICKS more"
SESSION_TYPE="wayland"; INSTANCES=(1 2); WAYLAND_REROUTE_SETTLE_TICKS=3; reset
wayland_settle_reroute
assert_eq "4" "$NUDGES"     # 1 immediate + 3 settle
assert_eq "3" "$SLEEPS"

test_case "settle loop sleeps the configured interval"
assert_eq "4" "$LAST_SLEEP"

test_case "Wayland + 2 instances, SETTLE_TICKS=0: only the immediate nudge"
SESSION_TYPE="wayland"; INSTANCES=(1 2); WAYLAND_REROUTE_SETTLE_TICKS=0; reset
wayland_settle_reroute
assert_eq "1" "$NUDGES"
assert_eq "0" "$SLEEPS"
WAYLAND_REROUTE_SETTLE_TICKS=3

trap _summary EXIT
