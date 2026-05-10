#!/usr/bin/env bash
# Tests for v6.10.0's --discover-streams subcommand and the
# corresponding doctor auto-discovery hook.
#
# The discovery probes a URL with curl. To test it offline we shim
# curl on PATH with a fake that returns fixture JSON for known
# hostnames and a 404-equivalent (exit 22, empty stdout) for anything
# else. Each test points the discoverer at a synthetic hostname like
# "test-frigate-default" and the shim returns the matching fixture.

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Build a curl shim that handles the URLs this test uses.
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cat >"$TMPDIR/curl" <<EOF
#!/usr/bin/env bash
# Mock curl: serve fixture JSON based on the URL passed as the
# last positional. Anything not in the switch returns exit 22
# (HTTP error, no body) — same effect as a 404 on real curl -fsSL.
url=\${@: -1}
case "\$url" in
  http://test-frigate-default/api/config)        cat "$FIXTURES_DIR/frigate-api-config.json" ;;
  http://test-frigate-rtsp-tcp/api/config)       cat "$FIXTURES_DIR/frigate-api-config-rtsp-tcp.json" ;;
  http://test-frigate-empty/api/config)          cat "$FIXTURES_DIR/frigate-api-config-no-streams.json" ;;
  http://test-go2rtc-direct/api/streams)         cat "$FIXTURES_DIR/go2rtc-api-streams.json" ;;
  http://test-down/api/config|http://test-down/api/streams) exit 7 ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$TMPDIR/curl"
export PATH="$TMPDIR:$PATH"

# ---- Frigate path: discovers streams + default RTSP port -----------------

test_case "Frigate + default rtsp.listen=':8554': lists streams"
run_kiosk --discover-streams http://test-frigate-default
assert_match 'Frigate detected' "$LAST_STDOUT"
assert_match 'rtsp://test-frigate-default:8554/birdseye' "$LAST_STDOUT"
assert_match 'rtsp://test-frigate-default:8554/front_door' "$LAST_STDOUT"
assert_match 'rtsp://test-frigate-default:8554/back_yard' "$LAST_STDOUT"

test_case "Frigate path: includes copy-pasteable conf snippet"
run_kiosk --discover-streams http://test-frigate-default
assert_match 'Suggested kiosk-monitor.conf snippet' "$LAST_STDOUT"
assert_match 'MODE="vlc"' "$LAST_STDOUT"
# First stream alphabetically is back_yard
assert_match 'URL="rtsp://test-frigate-default:8554/back_yard"' "$LAST_STDOUT"

test_case "Frigate path: streams sorted alphabetically"
run_kiosk --discover-streams http://test-frigate-default
# back_yard < birdseye < front_door
order=$(printf '%s\n' "$LAST_STDOUT" | grep -oE 'rtsp://[^:]+:[0-9]+/[a-z_]+' | sed 's|^.*/||' | head -3)
assert_eq "back_yard
birdseye
front_door" "$order"

test_case "Frigate path: exit code 0 when streams found"
run_kiosk --discover-streams http://test-frigate-default
assert_eq "0" "$LAST_RC"

# ---- Frigate path: alternate rtsp.listen formats parse correctly ---------

test_case "Frigate path: rtsp.listen='tcp://0.0.0.0:9999' is parsed"
run_kiosk --discover-streams http://test-frigate-rtsp-tcp
assert_match 'rtsp://test-frigate-rtsp-tcp:9999/birdseye' "$LAST_STDOUT"

# ---- Frigate path: empty go2rtc.streams ----------------------------------

test_case "Frigate with empty go2rtc.streams: exit 1, hint to add streams"
run_kiosk --discover-streams http://test-frigate-empty
assert_eq "1" "$LAST_RC"
assert_match 'no streams configured' "$LAST_STDOUT"
assert_match 'go2rtc.streams in Frigate config.yml' "$LAST_STDOUT"

# ---- go2rtc-direct path: falls back to /api/streams when /api/config 404s ----

test_case "go2rtc direct (no Frigate /api/config): falls back to /api/streams"
run_kiosk --discover-streams http://test-go2rtc-direct
assert_match 'go2rtc detected' "$LAST_STDOUT"
assert_match 'rtsp://test-go2rtc-direct:8554/birdseye' "$LAST_STDOUT"
assert_match 'rtsp://test-go2rtc-direct:8554/front_door' "$LAST_STDOUT"

# ---- unreachable host: clear error + exit 1 ------------------------------

test_case "unreachable host: exit 1, mentions both probe URLs"
run_kiosk --discover-streams http://test-down
assert_eq "1" "$LAST_RC"
assert_match 'neither.*api/config.*nor.*api/streams' "$LAST_STDERR"

# ---- usage error: no URL given ------------------------------------------

test_case "no URL argument: usage to stderr, exit 2"
run_kiosk --discover-streams
assert_eq "2" "$LAST_RC"
assert_match 'usage: kiosk-monitor --discover-streams' "$LAST_STDERR"

# ---- trailing slash on URL doesn't double up ----------------------------

test_case "trailing slash on URL: probes the right endpoint"
run_kiosk --discover-streams http://test-frigate-default/
assert_match 'Frigate detected' "$LAST_STDOUT"
assert_match 'rtsp://test-frigate-default:8554/birdseye' "$LAST_STDOUT"

trap _summary EXIT
