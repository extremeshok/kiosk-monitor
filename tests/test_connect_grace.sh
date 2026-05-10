#!/usr/bin/env bash
# Tests for the VLC / Chromium connect-grace gate added in v6.9.2:
# don't count stall ticks toward the freeze threshold until the
# watchdog has observed a hash *transition* (i.e. evidence the
# player rendered at least one different frame).
#
# The state machine lives inside the watchdog while-loop and is hard
# to unit-test against the real script. Instead, we replay the same
# logic as a standalone tick() function that takes the current hash
# and the previous instance state, and assert the post-tick state
# matches what the real script would produce.

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Reproduce the watchdog's stall-detection branch as a single tick.
# Mutates four state variables passed by name (bash 4.3+ namerefs).
# Returns nothing; counter / hash / flag mutate in place. Mirrors the
# code under "# 4. freeze / stall detection via per-output hash" in
# kiosk-monitor.sh ~L4326.
watchdog_tick() {
  local curr_hash=$1
  local -n _last_hash=$2
  local -n _stall_count=$3
  local -n _first_frame_seen=$4

  if [ -n "$_last_hash" ] && [ "$curr_hash" = "$_last_hash" ]; then
    if [ "${_first_frame_seen:-no}" = "yes" ]; then
      _stall_count=$((_stall_count + 1))
    fi
  else
    if [ -n "$_last_hash" ] && [ "${_first_frame_seen:-no}" != "yes" ]; then
      _first_frame_seen="yes"
    fi
    _stall_count=0
    _last_hash=$curr_hash
  fi
}

# ---- the failure case the gate exists for: stream never connects --------

test_case "uniform-frame stream never increments stall counter"
last_hash=""
stall_count=0
first_frame_seen="no"
# Simulate 10 ticks of capturing the same black-frame hash. Without
# the gate, stall_count would be 9 by the end and the watchdog would
# restart-loop. With the gate, it stays at 0.
for _ in $(seq 1 10); do
  watchdog_tick "BLACKFRAMEHASH" last_hash stall_count first_frame_seen
done
assert_eq "0" "$stall_count"

test_case "uniform-frame run leaves first_frame_seen=no"
# Same scenario as above — the gate must NOT have flipped since no
# transition occurred.
last_hash=""
stall_count=0
first_frame_seen="no"
for _ in $(seq 1 5); do
  watchdog_tick "X" last_hash stall_count first_frame_seen
done
assert_eq "no" "$first_frame_seen"

# ---- normal case: real stream renders, hash changes, stall trips --------

test_case "first hash transition flips first_frame_seen=yes"
last_hash=""
stall_count=0
first_frame_seen="no"
watchdog_tick "FRAME_A" last_hash stall_count first_frame_seen   # initial capture
watchdog_tick "FRAME_B" last_hash stall_count first_frame_seen   # transition
assert_eq "yes" "$first_frame_seen"

test_case "after first transition, repeated identical hashes increment counter"
last_hash=""
stall_count=0
first_frame_seen="no"
watchdog_tick "FRAME_A" last_hash stall_count first_frame_seen   # initial
watchdog_tick "FRAME_B" last_hash stall_count first_frame_seen   # transition (gate flips)
watchdog_tick "FRAME_B" last_hash stall_count first_frame_seen   # stall +1
watchdog_tick "FRAME_B" last_hash stall_count first_frame_seen   # stall +1
watchdog_tick "FRAME_B" last_hash stall_count first_frame_seen   # stall +1
assert_eq "3" "$stall_count"

test_case "hash change after stall resets counter to 0"
last_hash=""
stall_count=0
first_frame_seen="no"
watchdog_tick "A" last_hash stall_count first_frame_seen
watchdog_tick "B" last_hash stall_count first_frame_seen
watchdog_tick "B" last_hash stall_count first_frame_seen   # stall=1
watchdog_tick "B" last_hash stall_count first_frame_seen   # stall=2
watchdog_tick "C" last_hash stall_count first_frame_seen   # transition → reset
assert_eq "0" "$stall_count"

# ---- delayed-connect case: black for a while, then video starts ---------

test_case "delayed connect: stall counter stays at 0 until first transition"
last_hash=""
stall_count=0
first_frame_seen="no"
# Five black-frame ticks, then video starts and frames change.
for _ in $(seq 1 5); do
  watchdog_tick "BLACK" last_hash stall_count first_frame_seen
done
assert_eq "0" "$stall_count"
assert_eq "no" "$first_frame_seen"

test_case "delayed connect: gate flips on first frame change after black period"
last_hash=""
stall_count=0
first_frame_seen="no"
for _ in $(seq 1 5); do
  watchdog_tick "BLACK" last_hash stall_count first_frame_seen
done
watchdog_tick "FRAME1" last_hash stall_count first_frame_seen   # gate flips
watchdog_tick "FRAME2" last_hash stall_count first_frame_seen
assert_eq "yes" "$first_frame_seen"

test_case "delayed connect: stalling AFTER the connect counts normally"
last_hash=""
stall_count=0
first_frame_seen="no"
for _ in $(seq 1 5); do watchdog_tick "BLACK" last_hash stall_count first_frame_seen; done
watchdog_tick "FRAME1" last_hash stall_count first_frame_seen   # gate flips
watchdog_tick "FRAME1" last_hash stall_count first_frame_seen   # +1
watchdog_tick "FRAME1" last_hash stall_count first_frame_seen   # +1
watchdog_tick "FRAME1" last_hash stall_count first_frame_seen   # +1
assert_eq "3" "$stall_count"

# ---- structural: state vars exist in the script ------------------------

test_case "INSTANCE_FIRST_FRAME_SEEN array is declared in kiosk-monitor.sh"
grep -q '^declare -A INSTANCE_FIRST_FRAME_SEEN' "$SCRIPT"

test_case "setup_instances initialises INSTANCE_FIRST_FRAME_SEEN to 'no'"
grep -q 'INSTANCE_FIRST_FRAME_SEEN\[\$id\]="no"' "$SCRIPT"

test_case "record_restart_instance re-arms INSTANCE_FIRST_FRAME_SEEN"
# Look for the no-reset adjacent to the launch_instance call in the
# record_restart_instance function. The script comments that block
# with "Re-arm the connect-grace gate".
grep -q 'Re-arm the connect-grace gate' "$SCRIPT"

trap _summary EXIT
