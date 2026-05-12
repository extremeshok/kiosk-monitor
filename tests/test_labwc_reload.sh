#!/usr/bin/env bash
# Tests for reload_labwc_window_rules — the v6.11.2 fix that nudges
# labwc's rc.xml content (so labwc 0.9.x re-applies <windowRule>s to
# already-mapped surfaces) before SIGHUP. A bare SIGHUP without a
# content change is a no-op for re-evaluation in labwc 0.9.x, which is
# what caused the dual-VLC placement race (VLC sets its xdg_toplevel
# title after the surface is mapped, so labwc's title-match rule misses
# the initial mapping and only kicks in if rc.xml changes).
#
# What's covered:
#  - X11 short-circuit (returns 0 without touching the file or SIGHUP'ing)
#  - rc.xml missing (still SIGHUPs; no crash)
#  - rc.xml present but unmanaged (no marker) → file untouched, still SIGHUP
#  - rc.xml managed (has marker) → relayout-nudge comment inserted at top
#  - Idempotency: N consecutive calls leave exactly ONE relayout-nudge line
#    (regression guard — the dedupe sed must drop prior markers)
#  - Fresh timestamps: two calls produce different nudge timestamps
#
# Function uses KIOSK_LABWC_RC_XML env var (test-only override) to point
# at a tmp rc.xml instead of /home/$GUI_USER/.config/labwc/rc.xml.

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_functions reload_labwc_window_rules

# Stub as_gui so file ops run as the test user (no sudo needed in CI).
as_gui() { "$@"; }
export -f as_gui

# Stub pkill so we count invocations without actually signaling labwc.
PKILL_CALLS=0
PKILL_LAST_ARGS=""
pkill() { PKILL_CALLS=$((PKILL_CALLS + 1)); PKILL_LAST_ARGS="$*"; return 0; }
export -f pkill

# Helper: write a managed rc.xml fixture to the given path.
_write_managed_rc() {
  cat > "$1" <<'XML'
<?xml version="1.0"?>
<!-- kiosk-monitor: managed rc.xml — remove this comment to opt out of auto-management -->
<labwc_config>
  <windowRules>
    <windowRule title="kiosk-monitor-vlc-1"><action name="MoveToOutput" output="HDMI-A-1"/></windowRule>
  </windowRules>
</labwc_config>
XML
}

_write_unmanaged_rc() {
  cat > "$1" <<'XML'
<?xml version="1.0"?>
<labwc_config>
  <theme><name>default</name></theme>
</labwc_config>
XML
}

# Required globals.
export GUI_USER="testuser"

# ---- X11 short-circuit ------------------------------------------------

test_case "X11 session: returns 0 and does NOT touch file or call pkill"
export SESSION_TYPE="x11"
tmp_rc=$(mktemp); _write_managed_rc "$tmp_rc"
before_hash=$(md5sum "$tmp_rc" | cut -d' ' -f1)
before_calls=$PKILL_CALLS
KIOSK_LABWC_RC_XML="$tmp_rc" reload_labwc_window_rules
after_hash=$(md5sum "$tmp_rc" | cut -d' ' -f1)
[ "$before_hash" = "$after_hash" ] || _fail "rc.xml was modified during X11 short-circuit"
[ "$PKILL_CALLS" -eq "$before_calls" ] || _fail "pkill was called during X11 short-circuit ($PKILL_CALLS vs $before_calls)"
rm -f "$tmp_rc"
_pass

# ---- Wayland: rc.xml missing -----------------------------------------

test_case "Wayland, missing rc.xml: SIGHUP still fires, no crash"
export SESSION_TYPE="wayland"
missing_rc="/tmp/test-labwc-missing-$$.xml"
rm -f "$missing_rc"
before_calls=$PKILL_CALLS
set +e
KIOSK_LABWC_RC_XML="$missing_rc" reload_labwc_window_rules
rc=$?
set -e
[ "$rc" -eq 0 ] || _fail "expected exit 0, got $rc"
[ "$PKILL_CALLS" -eq $((before_calls + 1)) ] || _fail "expected one pkill call, got $((PKILL_CALLS - before_calls))"
_pass

# ---- Wayland: unmanaged rc.xml ---------------------------------------

test_case "Wayland, unmanaged rc.xml (no marker): file untouched, pkill still called"
tmp_rc=$(mktemp); _write_unmanaged_rc "$tmp_rc"
before_hash=$(md5sum "$tmp_rc" | cut -d' ' -f1)
before_calls=$PKILL_CALLS
KIOSK_LABWC_RC_XML="$tmp_rc" reload_labwc_window_rules
after_hash=$(md5sum "$tmp_rc" | cut -d' ' -f1)
[ "$before_hash" = "$after_hash" ] || _fail "unmanaged rc.xml was modified (should be left alone)"
[ "$PKILL_CALLS" -eq $((before_calls + 1)) ] || _fail "expected one pkill call"
rm -f "$tmp_rc"
_pass

# ---- Wayland: managed rc.xml inserts nudge ---------------------------

test_case "Wayland, managed rc.xml: relayout-nudge comment inserted near top"
tmp_rc=$(mktemp); _write_managed_rc "$tmp_rc"
before_calls=$PKILL_CALLS
KIOSK_LABWC_RC_XML="$tmp_rc" reload_labwc_window_rules
grep -q '<!-- kiosk-monitor: relayout-nudge:' "$tmp_rc" || _fail "no relayout-nudge marker after call"
[ "$PKILL_CALLS" -eq $((before_calls + 1)) ] || _fail "expected one pkill call"
rm -f "$tmp_rc"
_pass

test_case "Wayland, managed rc.xml: nudge appears on a line by itself (not breaking XML mid-tag)"
tmp_rc=$(mktemp); _write_managed_rc "$tmp_rc"
KIOSK_LABWC_RC_XML="$tmp_rc" reload_labwc_window_rules
# The nudge line should match the exact pattern <!-- ... --> on its own.
nudge_line=$(grep '<!-- kiosk-monitor: relayout-nudge:' "$tmp_rc")
assert_match '^<!-- kiosk-monitor: relayout-nudge: [0-9]+-[0-9]+-[0-9]+T[0-9]+:[0-9]+:[0-9]+\.[0-9]+ -->$' "$nudge_line"
rm -f "$tmp_rc"

# ---- Idempotency: no marker accumulation -----------------------------

test_case "Idempotency: 5 consecutive calls leave exactly ONE relayout-nudge line"
tmp_rc=$(mktemp); _write_managed_rc "$tmp_rc"
for _ in 1 2 3 4 5; do
  KIOSK_LABWC_RC_XML="$tmp_rc" reload_labwc_window_rules
  # Sleep just long enough for the timestamp to change, otherwise the
  # "fresh timestamp" assertion below could see identical values.
  sleep 0.05
done
marker_count=$(grep -c '<!-- kiosk-monitor: relayout-nudge:' "$tmp_rc" || true)
assert_eq "1" "$marker_count"
rm -f "$tmp_rc"

test_case "Idempotency: file size stays bounded (no append-only growth)"
tmp_rc=$(mktemp); _write_managed_rc "$tmp_rc"
KIOSK_LABWC_RC_XML="$tmp_rc" reload_labwc_window_rules
size_after_1=$(stat -c%s "$tmp_rc" 2>/dev/null || stat -f%z "$tmp_rc")
for _ in 1 2 3 4 5 6 7 8 9 10; do
  KIOSK_LABWC_RC_XML="$tmp_rc" reload_labwc_window_rules
done
size_after_11=$(stat -c%s "$tmp_rc" 2>/dev/null || stat -f%z "$tmp_rc")
# Difference must be just timestamp-format jitter — well under 50 bytes.
diff=$(( size_after_11 - size_after_1 ))
[ "${diff#-}" -lt 50 ] || _fail "file grew $diff bytes across 10 extra calls — marker dedupe broken"
rm -f "$tmp_rc"
_pass

# ---- Fresh timestamps -------------------------------------------------

test_case "Two calls produce different nudge timestamps"
tmp_rc=$(mktemp); _write_managed_rc "$tmp_rc"
KIOSK_LABWC_RC_XML="$tmp_rc" reload_labwc_window_rules
ts1=$(grep '<!-- kiosk-monitor: relayout-nudge:' "$tmp_rc")
sleep 0.05
KIOSK_LABWC_RC_XML="$tmp_rc" reload_labwc_window_rules
ts2=$(grep '<!-- kiosk-monitor: relayout-nudge:' "$tmp_rc")
assert_ne "$ts1" "$ts2"
rm -f "$tmp_rc"

# ---- pkill invocation shape ------------------------------------------

test_case "pkill is invoked with SIGHUP, -u GUI_USER, -x labwc"
tmp_rc=$(mktemp); _write_managed_rc "$tmp_rc"
KIOSK_LABWC_RC_XML="$tmp_rc" reload_labwc_window_rules
assert_match 'SIGHUP' "$PKILL_LAST_ARGS"
assert_match '-u testuser' "$PKILL_LAST_ARGS"
assert_match '-x labwc' "$PKILL_LAST_ARGS"
rm -f "$tmp_rc"

trap _summary EXIT
