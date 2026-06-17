#!/usr/bin/env bash
# Tests for vlc_hardening_flags — the VLC live-stream hardening flag builder
# added to stop the "grey screen, then footage returns" symptom.
#
# Background: a restreamed Frigate birdseye delivers frames with an uneven
# cadence. VLC's PCR arrives "late", it inflates pts_delay (default
# --clock-jitter is 5000ms) until it loses the reference clock and stops
# painting (grey screen). The hardening pins a jitter buffer, forces
# RTSP-over-TCP, and sets --clock-jitter=0 for live-stream URLs.
#
# What's covered:
#  - auto: rtsp/rtsps/rtmp/rtmps/udp get hardening; http/file do not
#  - rtsp/rtsps additionally get --rtsp-tcp; rtmp/udp do not
#  - --clock-jitter uses VLC_CLOCK_JITTER (default 0)
#  - network cache: default applied only when VLC_NETWORK_CACHING is unset
#  - VLC_RTSP_HARDENING=false opts out entirely; =true forces on for any URL

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_function vlc_hardening_flags

# Defaults the function reads (mirrors the config block).
VLC_RTSP_HARDENING="auto"
VLC_CLOCK_JITTER="0"
VLC_CLOCK_SYNCHRO="0"
VLC_NETWORK_CACHING=""
VLC_NETWORK_CACHING_DEFAULT="1500"

# Collect flags for a URL as a single space-joined string for easy matching.
flags_for() { vlc_hardening_flags "$1" | tr '\n' ' '; }

# --- auto-detection by URL scheme -------------------------------------
test_case "auto: rtsp gets clock-jitter=0"
out=$(flags_for "rtsp://admin:x@192.168.3.222:30060/birdseye")
assert_match "clock-jitter=0" "$out"
test_case "auto: rtsp gets clock-synchro=0"
assert_match "clock-synchro=0" "$out"
test_case "auto: rtsp gets --rtsp-tcp"
assert_match "rtsp-tcp" "$out"
test_case "auto: rtsp gets default network cache"
assert_match "network-caching=1500" "$out"

test_case "auto: rtsps is hardened and gets --rtsp-tcp"
out=$(flags_for "rtsps://host/stream")
assert_match "rtsp-tcp" "$out"

test_case "auto: rtmp is hardened (clock-jitter) but no --rtsp-tcp"
out=$(flags_for "rtmp://host/app/stream")
assert_match "clock-jitter=0" "$out"
assert_no_match "rtsp-tcp" "$out"

test_case "auto: udp is hardened, no --rtsp-tcp"
out=$(flags_for "udp://@239.0.0.1:1234")
assert_match "clock-jitter=0" "$out"
assert_no_match "rtsp-tcp" "$out"

test_case "auto: http(s) is NOT hardened (empty)"
out=$(flags_for "http://192.168.3.222:30059/#birdseye")
assert_eq "" "${out// /}"

test_case "auto: local file is NOT hardened (empty)"
out=$(flags_for "file:///media/loop.mp4")
assert_eq "" "${out// /}"

# --- VLC_CLOCK_JITTER override ----------------------------------------
test_case "VLC_CLOCK_JITTER override is honored"
VLC_CLOCK_JITTER="800"
out=$(flags_for "rtsp://host/s")
assert_match "clock-jitter=800" "$out"
VLC_CLOCK_JITTER="0"

# --- VLC_CLOCK_SYNCHRO --------------------------------------------------
test_case "VLC_CLOCK_SYNCHRO=-1 restores VLC default (omits the flag)"
VLC_CLOCK_SYNCHRO="-1"
out=$(flags_for "rtsp://host/s")
assert_no_match "clock-synchro" "$out"
VLC_CLOCK_SYNCHRO="0"

# --- network cache precedence -----------------------------------------
test_case "explicit VLC_NETWORK_CACHING suppresses the hardening default cache"
VLC_NETWORK_CACHING="3000"
out=$(flags_for "rtsp://host/s")
# hardening must NOT emit its own --network-caching (the launcher adds the
# explicit one separately, which would otherwise duplicate/conflict)
assert_no_match "network-caching" "$out"
VLC_NETWORK_CACHING=""

test_case "VLC_NETWORK_CACHING_DEFAULT override is honored"
VLC_NETWORK_CACHING_DEFAULT="2500"
out=$(flags_for "rtsp://host/s")
assert_match "network-caching=2500" "$out"
VLC_NETWORK_CACHING_DEFAULT="1500"

# --- master switch -----------------------------------------------------
test_case "VLC_RTSP_HARDENING=false opts out entirely"
VLC_RTSP_HARDENING="false"
out=$(flags_for "rtsp://host/s")
assert_eq "" "${out// /}"

test_case "VLC_RTSP_HARDENING=true forces hardening on a plain http URL"
VLC_RTSP_HARDENING="true"
out=$(flags_for "http://host/stream.m3u8")
assert_match "clock-jitter=0" "$out"
assert_no_match "rtsp-tcp" "$out"
VLC_RTSP_HARDENING="auto"

trap _summary EXIT
