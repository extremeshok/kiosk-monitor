#!/usr/bin/env bash
# Tests for URL-classification helpers: is_frigate_birdseye_url and
# _url_looks_like_media_for_vlc. Both are pure-function tests — no
# external state required.

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_functions is_frigate_birdseye_url _url_looks_like_media_for_vlc

# ---- is_frigate_birdseye_url ------------------------------------------

test_case "is_frigate_birdseye_url: no query → no-match"
assert_fails "plain root" is_frigate_birdseye_url "http://192.168.3.92:30059/"

test_case "is_frigate_birdseye_url: ?Birdseye (capitalized)"
assert_succeeds "capitalized Birdseye query" is_frigate_birdseye_url "http://192.168.1.194:30059/?Birdseye"

test_case "is_frigate_birdseye_url: ?birdseye (lowercase)"
assert_succeeds "lowercase birdseye query" is_frigate_birdseye_url "http://192.168.1.194:30059/?birdseye"

test_case "is_frigate_birdseye_url: ?birdseye=value"
assert_succeeds "birdseye with value" is_frigate_birdseye_url "http://example.com/?birdseye=1"

test_case "is_frigate_birdseye_url: &birdseye after another param"
assert_succeeds "amp-birdseye" is_frigate_birdseye_url "http://example.com/foo?bar=1&birdseye"

test_case "is_frigate_birdseye_url: API path is not Birdseye"
assert_fails "api/config" is_frigate_birdseye_url "http://192.168.3.92:30059/api/config"

test_case "is_frigate_birdseye_url: live-mode query is not Birdseye"
assert_fails "live=jsmpeg" is_frigate_birdseye_url "http://192.168.3.92:30059/?live=jsmpeg"

test_case "is_frigate_birdseye_url: #birdseye hash-route (Frigate's native form)"
assert_succeeds "hash birdseye" is_frigate_birdseye_url "http://192.168.3.92:30059/#birdseye"

test_case "is_frigate_birdseye_url: #birdseye/sub path"
assert_succeeds "hash birdseye sub" is_frigate_birdseye_url "http://192.168.3.92:30059/#birdseye/grid"

test_case "is_frigate_birdseye_url: #birdseye? with query"
assert_succeeds "hash birdseye qs" is_frigate_birdseye_url "http://192.168.3.92:30059/#birdseye?camera=1"

test_case "is_frigate_birdseye_url: #birdwatch (not Birdseye)"
assert_fails "hash birdwatch" is_frigate_birdseye_url "http://192.168.3.92:30059/#birdwatch"

# ---- _url_looks_like_media_for_vlc ------------------------------------

test_case "vlc-media: HTML root is NOT media"
assert_fails "plain root" _url_looks_like_media_for_vlc "http://192.168.3.92:30059/"

test_case "vlc-media: Frigate ?Birdseye URL is NOT media"
assert_fails "frigate birdseye web ui" _url_looks_like_media_for_vlc "http://192.168.1.194:30059/?Birdseye"

test_case "vlc-media: API path is NOT media"
assert_fails "api/config" _url_looks_like_media_for_vlc "http://192.168.3.92:30059/api/config"

test_case "vlc-media: .mp4 extension is media"
assert_succeeds ".mp4" _url_looks_like_media_for_vlc "http://example.com/video.mp4"

test_case "vlc-media: .MP4 case-insensitive"
assert_succeeds "uppercase ext" _url_looks_like_media_for_vlc "https://example.com/foo.MP4?token=abc"

test_case "vlc-media: .m3u8 manifest is media"
assert_succeeds ".m3u8" _url_looks_like_media_for_vlc "http://example.com/playlist.m3u8"

test_case "vlc-media: .mpd manifest is media"
assert_succeeds ".mpd (DASH)" _url_looks_like_media_for_vlc "http://example.com/manifest.mpd"

test_case "vlc-media: ?stream= query is media"
assert_succeeds "?stream=" _url_looks_like_media_for_vlc "http://example.com/cam?stream=main"

test_case "vlc-media: /live/ path segment is media"
assert_succeeds "/live/" _url_looks_like_media_for_vlc "http://example.com/path/live/stream"

test_case "vlc-media: ?format=mp4 query is media"
assert_succeeds "?format=mp4" _url_looks_like_media_for_vlc "http://example.com/api?format=mp4&token=xyz"

test_case "vlc-media: ?live=cam1 query is media"
assert_succeeds "?live=" _url_looks_like_media_for_vlc "https://example.com/api/play?live=cam1"

trap _summary EXIT
