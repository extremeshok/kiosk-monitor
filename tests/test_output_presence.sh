#!/usr/bin/env bash
# Tests for the output-presence / pause-on-disconnect hardening.
#
# Background: on a dual-display kiosk the VLC feed was intermittently
# dropping to the bare desktop for minutes at a time even though the HDMI
# link never physically dropped (no kernel hotplug event). Root cause was a
# false-negative in the watchdog's output detection:
#
#   refresh_outputs() cleared OUTPUTS_NAMES up front, then a single transient
#   wlr-randr/python3 failure left it EMPTY and returned. The caller read that
#   as "every output disconnected", instance_output_present() returned false,
#   and the instance was paused (VLC killed) until a later poll happened to
#   succeed.
#
# What's covered:
#  - refresh_outputs commits a good reading to OUTPUTS_NAMES (wayland path)
#  - refresh_outputs preserves the LAST-KNOWN-GOOD list when wlr-randr fails
#    (the headline regression: a transient poll failure must not blank it)
#  - refresh_outputs preserves the list on an empty/garbage parse
#  - refresh_outputs reflects a genuine single-output reading (real unplug)
#  - instance_output_present: true when listed, true for auto-pick (no OUTPUT)
#  - instance_output_present: false when absent AND the kernel DRM status says
#    disconnected (or is missing)
#  - instance_output_present: KERNEL FALLBACK — false from wlr-randr but the
#    DRM connector still reads "connected" => treated as present (no pause)
#
# instance_output_present consults KIOSK_DRM_DIR (test-only override for the
# /sys/class/drm base) so the kernel-truth fallback is testable off a Pi.

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_functions refresh_outputs _refresh_outputs_x11 instance_output_present

# --- globals the functions read/write ---------------------------------
declare -A OUTPUT_GEOMETRY=()
OUTPUTS_NAMES=()
declare -A INSTANCE_OUTPUT=()
SESSION_TYPE="wayland"

# A KIOSK_DRM_DIR with no matching connector, so the kernel fallback stays
# inert for the refresh_outputs / list-match tests below.
EMPTY_DRM=$(mktemp -d)
export KIOSK_DRM_DIR="$EMPTY_DRM"

# Put a stub wlr-randr on PATH so `command -v wlr-randr` succeeds; as_gui is
# overridden below so the stub is never actually executed.
FAKEBIN=$(mktemp -d)
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKEBIN/wlr-randr"
chmod +x "$FAKEBIN/wlr-randr"
PATH="$FAKEBIN:$PATH"

# Mock the GUI wrapper: returns $MOCK_WLR_JSON (rc 0) or fails (rc 1).
MOCK_WLR_OK=1
MOCK_WLR_JSON=""
as_gui() {
  if [ "$MOCK_WLR_OK" = "1" ]; then
    printf '%s' "$MOCK_WLR_JSON"
    return 0
  fi
  return 1
}

cleanup() { rm -rf "$FAKEBIN" "$EMPTY_DRM" "${DRM_OK:-}"; }
trap 'cleanup; _summary' EXIT

mk_output() { # name x w
  printf '{"name":"%s","enabled":true,"position":{"x":%s,"y":0},"modes":[{"current":true,"width":%s,"height":1080}]}' "$1" "$2" "$3"
}
TWO_OUTPUTS="[$(mk_output HDMI-A-1 0 1920),$(mk_output HDMI-A-2 1920 1920)]"
ONE_OUTPUT="[$(mk_output HDMI-A-1 0 1920)]"

# --- refresh_outputs ---------------------------------------------------
test_case "refresh_outputs populates OUTPUTS_NAMES on a good poll"
MOCK_WLR_OK=1; MOCK_WLR_JSON="$TWO_OUTPUTS"
refresh_outputs
assert_eq "HDMI-A-1 HDMI-A-2" "${OUTPUTS_NAMES[*]}"

test_case "refresh_outputs returns non-zero when wlr-randr fails"
MOCK_WLR_OK=0; MOCK_WLR_JSON=""
assert_fails "poll failed" refresh_outputs

test_case "refresh_outputs preserves last-good list when wlr-randr fails"
# OUTPUTS_NAMES must still hold the previous good reading, NOT be blanked.
assert_eq "HDMI-A-1 HDMI-A-2" "${OUTPUTS_NAMES[*]}"

test_case "refresh_outputs preserves last-good list on empty parse"
MOCK_WLR_OK=1; MOCK_WLR_JSON="[]"
assert_fails "empty parse" refresh_outputs
assert_eq "HDMI-A-1 HDMI-A-2" "${OUTPUTS_NAMES[*]}"

test_case "refresh_outputs reflects a genuine single-output reading"
MOCK_WLR_OK=1; MOCK_WLR_JSON="$ONE_OUTPUT"
refresh_outputs
assert_eq "HDMI-A-1" "${OUTPUTS_NAMES[*]}"

# --- instance_output_present ------------------------------------------
test_case "instance_output_present true when output in list"
OUTPUTS_NAMES=( "HDMI-A-1" "HDMI-A-2" )
INSTANCE_OUTPUT[2]="HDMI-A-2"
assert_succeeds "HDMI-A-2 listed" instance_output_present 2

test_case "instance_output_present true for auto-pick (no explicit output)"
INSTANCE_OUTPUT[9]=""
assert_succeeds "auto-pick" instance_output_present 9

test_case "instance_output_present false when absent and DRM disconnected"
OUTPUTS_NAMES=( "HDMI-A-1" )
INSTANCE_OUTPUT[2]="HDMI-A-2"
# KIOSK_DRM_DIR (EMPTY_DRM) has no card*-HDMI-A-2/status, so the fallback
# cannot fire and the output is correctly reported absent.
assert_fails "HDMI-A-2 absent, no DRM" instance_output_present 2

test_case "instance_output_present kernel fallback: DRM connected => present"
# wlr-randr dropped HDMI-A-2 from its list, but the kernel connector still
# reads "connected" (compositor/wlr-randr stall). Must NOT report absent.
DRM_OK=$(mktemp -d)
mkdir -p "$DRM_OK/card1-HDMI-A-2"
printf 'connected\n' >"$DRM_OK/card1-HDMI-A-2/status"
OUTPUTS_NAMES=( "HDMI-A-1" )
INSTANCE_OUTPUT[2]="HDMI-A-2"
KIOSK_DRM_DIR="$DRM_OK" assert_succeeds "DRM connected" instance_output_present 2

test_case "instance_output_present kernel fallback: DRM disconnected => absent"
printf 'disconnected\n' >"$DRM_OK/card1-HDMI-A-2/status"
KIOSK_DRM_DIR="$DRM_OK" assert_fails "DRM disconnected" instance_output_present 2
