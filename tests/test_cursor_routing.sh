#!/usr/bin/env bash
# Tests for the Wayland cursor-placement routing helpers added to put a
# fullscreen VLC on its target output (labwc's MoveToOutput is a no-op on
# fullscreen windows, so we warp the pointer onto the output and let placement
# policy "cursor" map the window there).
#
# Strategy: load the helpers, put a stub `wlrctl` on PATH so `command -v`
# succeeds, and mock `as_gui` to record the commands it would run.
#
# Covered:
#  - cursor_routing_enabled gating (session type, master switch, wlrctl present)
#  - warp_cursor_to_output computes the right pointer target from geometry
#  - warp is a no-op when disabled or geometry is unknown
#  - park_cursor moves toward the global origin

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_functions cursor_routing_enabled warp_cursor_to_output park_cursor

declare -A OUTPUT_GEOMETRY=( [HDMI-A-1]="0 0 3840 2160" [HDMI-A-2]="3840 0 1600 900" )
SESSION_TYPE="wayland"
WAYLAND_CURSOR_ROUTING="auto"

# stub wlrctl so `command -v wlrctl` succeeds (as_gui is mocked, so it's never run)
FAKEBIN=$(mktemp -d); printf '#!/usr/bin/env bash\n' >"$FAKEBIN/wlrctl"; chmod +x "$FAKEBIN/wlrctl"
PATH="$FAKEBIN:$PATH"
trap 'rm -rf "$FAKEBIN"; _summary' EXIT

AS_GUI_CALLS=()
as_gui() { AS_GUI_CALLS+=("$*"); }
reset() { AS_GUI_CALLS=(); }
last_call() { [ "${#AS_GUI_CALLS[@]}" -gt 0 ] && printf '%s' "${AS_GUI_CALLS[${#AS_GUI_CALLS[@]}-1]}"; }

# --- cursor_routing_enabled -------------------------------------------
test_case "enabled on wayland + auto + wlrctl present"
SESSION_TYPE="wayland"; WAYLAND_CURSOR_ROUTING="auto"
assert_succeeds "enabled" cursor_routing_enabled

test_case "disabled off-wayland"
SESSION_TYPE="x11"
assert_fails "x11" cursor_routing_enabled
SESSION_TYPE="wayland"

test_case "disabled when WAYLAND_CURSOR_ROUTING=false"
WAYLAND_CURSOR_ROUTING="false"
assert_fails "off switch" cursor_routing_enabled
WAYLAND_CURSOR_ROUTING="auto"

# --- warp_cursor_to_output --------------------------------------------
test_case "warp to HDMI-A-2 targets just inside its top-left (3848,8)"
reset; warp_cursor_to_output "HDMI-A-2"
assert_eq "wlrctl pointer move 3848 8" "$(last_call)"

test_case "warp resets toward origin first (2 calls)"
assert_eq "2" "${#AS_GUI_CALLS[@]}"

test_case "warp to HDMI-A-1 targets (8,8)"
reset; warp_cursor_to_output "HDMI-A-1"
assert_eq "wlrctl pointer move 8 8" "$(last_call)"

test_case "warp is a no-op for an unknown output"
reset; warp_cursor_to_output "HDMI-A-9"
assert_eq "0" "${#AS_GUI_CALLS[@]}"

test_case "warp is a no-op when routing disabled"
WAYLAND_CURSOR_ROUTING="false"; reset; warp_cursor_to_output "HDMI-A-2"
assert_eq "0" "${#AS_GUI_CALLS[@]}"
WAYLAND_CURSOR_ROUTING="auto"

# --- park_cursor -------------------------------------------------------
test_case "park moves toward the global origin"
reset; park_cursor
assert_eq "wlrctl pointer move -20000 -20000" "$(last_call)"

test_case "park is a no-op when routing disabled"
WAYLAND_CURSOR_ROUTING="false"; reset; park_cursor
assert_eq "0" "${#AS_GUI_CALLS[@]}"
WAYLAND_CURSOR_ROUTING="auto"
