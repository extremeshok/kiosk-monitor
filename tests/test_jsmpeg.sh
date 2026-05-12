#!/usr/bin/env bash
# Tests for the v6.11 CHROME_VIA_JSMPEG path. The implementation lives
# inside the kiosk-monitor Chromium extension: when CHROME_VIA_JSMPEG
# is true, ensure_frigate_extension drops a `force-jsmpeg.js` shim into
# the per-instance extension dir and adds a `world: "MAIN"`
# content_scripts entry to the manifest. Chromium's extension loader
# runs that shim at document_start in the page's MAIN world, where it
# intercepts /api/config fetch + XHR responses and rewrites
# birdseye.restream to false. Frigate's React WebUI then picks the
# JSMpeg player path (not MSE, not WebRTC), sidestepping the Chromium
# 147 ChunkDemuxer freeze on Birdseye. Server-side config is untouched
# so VLC/HomeKit RTSP keeps working.
#
# These tests poke ensure_frigate_extension directly with a minimal
# fake instance and inspect the generated files. Browser-side semantics
# were verified end-to-end against a live Frigate 0.17.1 during v6.11
# dev (1920x1080 canvas mounted, no <video>).

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_functions \
  is_frigate_birdseye_url \
  derive_match_pattern \
  js_escape \
  ensure_frigate_extension

# Stub out logging so the function doesn't try to find a real log file.
log_instance() { :; }

# Workspace + minimal globals the function reads.
TMPDIR_TEST=$(mktemp -d -t kiosk-jsmpeg-tests-XXXXXX)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# These are normally declared at the top of kiosk-monitor.sh's runtime
# block; we synthesise just enough state to call ensure_frigate_extension.
declare -A INSTANCE_PROFILE_DIR=( [1]="$TMPDIR_TEST/profile-1" )
# Give INSTANCE_OUTPUT[1] a placeholder name + matching OUTPUT_GEOMETRY
# so the function's `${OUTPUT_GEOMETRY[$out_name]:-}` lookup doesn't
# blow up on an empty subscript under `set -u`.
declare -A INSTANCE_OUTPUT=( [1]="HDMI-A-1" )
declare -A OUTPUT_GEOMETRY=( [HDMI-A-1]="0 0 1920 1080" )
GUI_USER="${USER:-pi}"
FRIGATE_BIRDSEYE_EXTENSION_DIR=""
FRIGATE_BIRDSEYE_MATCH_PATTERN=""
FRIGATE_BIRDSEYE_WIDTH="" FRIGATE_BIRDSEYE_HEIGHT="" FRIGATE_BIRDSEYE_MARGIN=80
FRIGATE_THEME_STORAGE_KEY="frigate-ui-theme"
FRIGATE_COLOR_STORAGE_KEY="frigate-ui-color-scheme"

# Helper: clear extension dir + invoke the function with a clean state.
fresh_run() {
  rm -rf "$TMPDIR_TEST/profile-1"
  mkdir -p "$TMPDIR_TEST/profile-1"
  declare -A -g INSTANCE_URL=( [1]="http://frigate.test:30059/?birdseye" )
}

# ---- Early-return guard ------------------------------------------------

test_case "extension: skipped entirely when no Frigate knobs active"
fresh_run
FRIGATE_BIRDSEYE_AUTO_FILL="false"; FRIGATE_DARK_MODE=""; FRIGATE_THEME=""
CHROME_VIA_JSMPEG="false"
out=$(ensure_frigate_extension 1 2>/dev/null) && rc=0 || rc=$?
assert_eq "1" "$rc"

test_case "extension: emitted when only CHROME_VIA_JSMPEG=true"
fresh_run
FRIGATE_BIRDSEYE_AUTO_FILL="false"; FRIGATE_DARK_MODE=""; FRIGATE_THEME=""
CHROME_VIA_JSMPEG="true"
out=$(ensure_frigate_extension 1)
rc=$?
assert_eq "0" "$rc"

# ---- force-jsmpeg.js contents ------------------------------------------

test_case "force-jsmpeg.js: written when CHROME_VIA_JSMPEG=true"
fresh_run
FRIGATE_BIRDSEYE_AUTO_FILL="false"; FRIGATE_DARK_MODE=""; FRIGATE_THEME=""
CHROME_VIA_JSMPEG="true"
dir=$(ensure_frigate_extension 1)
[ -f "$dir/force-jsmpeg.js" ] && _pass || _fail "force-jsmpeg.js not present in $dir"

test_case "force-jsmpeg.js: overrides window.fetch"
got=$(grep -c 'window.fetch = function' "$dir/force-jsmpeg.js")
[ "$got" -ge 1 ] && _pass || _fail "expected window.fetch override; got count=$got"

test_case "force-jsmpeg.js: overrides XMLHttpRequest"
got=$(grep -c 'window.XMLHttpRequest = PatchedXHR' "$dir/force-jsmpeg.js")
[ "$got" -ge 1 ] && _pass || _fail "expected XMLHttpRequest override; got count=$got"

test_case "force-jsmpeg.js: rewrites birdseye.restream to false"
got=$(grep -c 'cfg.birdseye.restream = false' "$dir/force-jsmpeg.js")
[ "$got" -ge 1 ] && _pass || _fail "expected restream rewrite; got count=$got"

test_case "force-jsmpeg.js: scopes rewrite to /api/config (excludes /api/config/save and /api/config/raw)"
got=$(grep -c '/api/config/save\|/api/config/raw' "$dir/force-jsmpeg.js")
[ "$got" -ge 2 ] && _pass || _fail "expected /save and /raw exclusions; got count=$got"

test_case "force-jsmpeg.js: NOT written when CHROME_VIA_JSMPEG=false"
fresh_run
FRIGATE_BIRDSEYE_AUTO_FILL="false"; FRIGATE_DARK_MODE=""; FRIGATE_THEME="High Contrast"
CHROME_VIA_JSMPEG="false"
dir=$(ensure_frigate_extension 1)
[ ! -f "$dir/force-jsmpeg.js" ] && _pass || _fail "force-jsmpeg.js should be absent"

# ---- manifest.json structure ------------------------------------------

test_case "manifest: contains world:MAIN entry for force-jsmpeg.js when CHROME_VIA_JSMPEG=true"
fresh_run
FRIGATE_BIRDSEYE_AUTO_FILL="false"; FRIGATE_DARK_MODE=""; FRIGATE_THEME=""
CHROME_VIA_JSMPEG="true"
dir=$(ensure_frigate_extension 1)
got=$(python3 -c "
import json
m = json.load(open('$dir/manifest.json'))
worlds = [e.get('world') for e in m.get('content_scripts', [])]
jss = [s for e in m.get('content_scripts', []) for s in e.get('js', [])]
print('worlds=' + ','.join(str(w) for w in worlds))
print('js=' + ','.join(jss))
" 2>&1)
case "$got" in
  *worlds=*MAIN*) _pass ;;
  *) _fail "MAIN world missing from manifest. got: $got" ;;
esac

test_case "manifest: lists force-jsmpeg.js in scripts"
case "$got" in
  *js=*force-jsmpeg.js*) _pass ;;
  *) _fail "force-jsmpeg.js not in manifest scripts. got: $got" ;;
esac

test_case "manifest: NO world:MAIN entry when CHROME_VIA_JSMPEG=false"
fresh_run
FRIGATE_BIRDSEYE_AUTO_FILL="true"; FRIGATE_DARK_MODE="Dark"; FRIGATE_THEME=""
CHROME_VIA_JSMPEG="false"
dir=$(ensure_frigate_extension 1)
got=$(python3 -c "
import json
m = json.load(open('$dir/manifest.json'))
worlds = [e.get('world') for e in m.get('content_scripts', [])]
print(','.join(str(w) for w in worlds))
")
assert_eq "None" "$got"

test_case "manifest: TWO entries when CHROME_VIA_JSMPEG=true + autofill=true"
fresh_run
FRIGATE_BIRDSEYE_AUTO_FILL="true"; FRIGATE_DARK_MODE="Dark"; FRIGATE_THEME=""
CHROME_VIA_JSMPEG="true"
dir=$(ensure_frigate_extension 1)
count=$(python3 -c "
import json
m = json.load(open('$dir/manifest.json'))
print(len(m.get('content_scripts', [])))
")
assert_eq "2" "$count"

test_case "manifest: parses as valid JSON in all cases"
fresh_run
FRIGATE_BIRDSEYE_AUTO_FILL="false"; FRIGATE_DARK_MODE=""; FRIGATE_THEME=""
CHROME_VIA_JSMPEG="true"
dir=$(ensure_frigate_extension 1)
python3 -c "import json; json.load(open('$dir/manifest.json'))" && _pass || _fail "json-only run produced invalid manifest"

# ---- Match pattern carry-through --------------------------------------

test_case "manifest: both content_scripts entries use the same match pattern"
fresh_run
FRIGATE_BIRDSEYE_AUTO_FILL="true"; FRIGATE_DARK_MODE=""; FRIGATE_THEME=""
CHROME_VIA_JSMPEG="true"
INSTANCE_URL[1]="http://frigate.example.com:30059/?birdseye"
dir=$(ensure_frigate_extension 1)
distinct=$(python3 -c "
import json
m = json.load(open('$dir/manifest.json'))
matches = set()
for e in m.get('content_scripts', []):
    matches.update(e.get('matches', []))
print(len(matches))
")
assert_eq "1" "$distinct"

# ---- run_at safety ----------------------------------------------------

test_case "mse-disable entry: run_at is document_start (must precede page scripts)"
fresh_run
FRIGATE_BIRDSEYE_AUTO_FILL="false"; FRIGATE_DARK_MODE=""; FRIGATE_THEME=""
CHROME_VIA_JSMPEG="true"
dir=$(ensure_frigate_extension 1)
runat=$(python3 -c "
import json
m = json.load(open('$dir/manifest.json'))
for e in m.get('content_scripts', []):
    if 'force-jsmpeg.js' in e.get('js', []):
        print(e.get('run_at')); break
")
assert_eq "document_start" "$runat"

# ---- _resolve_chrome_via_jsmpeg_auto -----------------------------------
#
# Exercise the auto-resolver against a curl shim that returns canned
# /api/config responses for known hosts. Verifies the three reason codes
# the doctor branches on (frigate-restream-true / -false / -probe-failed)
# and the operator-set passthroughs.

# Stash curl shim in TMPDIR_TEST/bin
mkdir -p "$TMPDIR_TEST/bin"
cat > "$TMPDIR_TEST/bin/curl" <<'CURL'
#!/usr/bin/env bash
url=${!#}
case "$url" in
  *frigate-restream-true*/api/config)
    printf '{"birdseye":{"enabled":true,"restream":true}}' ;;
  *frigate-restream-false*/api/config)
    printf '{"birdseye":{"enabled":true,"restream":false}}' ;;
  *frigate-down*/api/config)
    exit 7 ;;
  *)
    exit 22 ;;
esac
CURL
chmod +x "$TMPDIR_TEST/bin/curl"
export PATH="$TMPDIR_TEST/bin:$PATH"

# Load the auto-resolver + supporting helpers. setup_instances depends on
# normalize_config_values etc., so we just synthesise INSTANCES + maps
# directly and skip setup_instances itself.
load_function _resolve_chrome_via_jsmpeg_auto
log() { :; }   # silence

reset_resolver_state() {
  CHROME_VIA_JSMPEG="auto"
  CHROME_VIA_JSMPEG_RESOLVED_REASON=""
  declare -g -A INSTANCE_MODE=()
  declare -g -A INSTANCE_URL=()
  declare -g -a INSTANCES=()
}

test_case "auto-resolve: operator-set true is passed through"
reset_resolver_state
CHROME_VIA_JSMPEG="true"
_resolve_chrome_via_jsmpeg_auto
assert_eq "true" "$CHROME_VIA_JSMPEG"
test_case "auto-resolve: operator-set-true reason recorded"
assert_eq "operator-set-true" "$CHROME_VIA_JSMPEG_RESOLVED_REASON"

test_case "auto-resolve: operator-set false is passed through"
reset_resolver_state
CHROME_VIA_JSMPEG="false"
_resolve_chrome_via_jsmpeg_auto
assert_eq "false" "$CHROME_VIA_JSMPEG"

test_case "auto-resolve: no chrome+birdseye instance → false + reason"
reset_resolver_state
_resolve_chrome_via_jsmpeg_auto
assert_eq "false" "$CHROME_VIA_JSMPEG"
test_case "auto-resolve: no-chrome-birdseye-instance reason"
assert_eq "no-chrome-birdseye-instance" "$CHROME_VIA_JSMPEG_RESOLVED_REASON"

test_case "auto-resolve: Frigate restream:true → true + frigate-restream-true reason"
reset_resolver_state
INSTANCES=(1)
INSTANCE_MODE[1]="chrome"
INSTANCE_URL[1]="http://frigate-restream-true.test:30059/#birdseye"
_resolve_chrome_via_jsmpeg_auto
assert_eq "true" "$CHROME_VIA_JSMPEG"
test_case "auto-resolve: frigate-restream-true reason recorded"
assert_eq "frigate-restream-true" "$CHROME_VIA_JSMPEG_RESOLVED_REASON"

test_case "auto-resolve: Frigate restream:false → false + frigate-restream-false reason"
reset_resolver_state
INSTANCES=(1)
INSTANCE_MODE[1]="chrome"
INSTANCE_URL[1]="http://frigate-restream-false.test:30059/?birdseye"
_resolve_chrome_via_jsmpeg_auto
assert_eq "false" "$CHROME_VIA_JSMPEG"
test_case "auto-resolve: frigate-restream-false reason recorded"
assert_eq "frigate-restream-false" "$CHROME_VIA_JSMPEG_RESOLVED_REASON"

test_case "auto-resolve: Frigate unreachable → false + frigate-probe-failed reason"
reset_resolver_state
INSTANCES=(1)
INSTANCE_MODE[1]="chrome"
INSTANCE_URL[1]="http://frigate-down.test:30059/?birdseye"
_resolve_chrome_via_jsmpeg_auto
assert_eq "false" "$CHROME_VIA_JSMPEG"
test_case "auto-resolve: frigate-probe-failed reason recorded"
assert_eq "frigate-probe-failed" "$CHROME_VIA_JSMPEG_RESOLVED_REASON"

test_case "auto-resolve: non-chrome instance ignored"
reset_resolver_state
INSTANCES=(1)
INSTANCE_MODE[1]="vlc"
INSTANCE_URL[1]="http://frigate-restream-true.test:30059/?birdseye"
_resolve_chrome_via_jsmpeg_auto
assert_eq "false" "$CHROME_VIA_JSMPEG"   # vlc not counted

test_case "auto-resolve: mixed (restream:true + restream:false) → true (any-true wins)"
reset_resolver_state
INSTANCES=(1 2)
INSTANCE_MODE[1]="chrome"
INSTANCE_URL[1]="http://frigate-restream-false.test:30059/?birdseye"
INSTANCE_MODE[2]="chrome"
INSTANCE_URL[2]="http://frigate-restream-true.test:30059/?birdseye"
_resolve_chrome_via_jsmpeg_auto
assert_eq "true" "$CHROME_VIA_JSMPEG"

# ---- _maybe_auto_flip_chrome_via_jsmpeg_on_freeze ----------------------
#
# Reactive safety-net path: when a chrome+birdseye instance stalls, the
# watchdog asks "should I auto-enable the shim and rebuild on restart?".
# The helper re-probes Frigate /api/config and flips when restream:true.

load_function _maybe_auto_flip_chrome_via_jsmpeg_on_freeze

reset_recover_state() {
  CHROME_VIA_JSMPEG="false"
  CHROME_VIA_JSMPEG_RESOLVED_REASON=""
  declare -g -A INSTANCE_MODE=( [1]="chrome" )
  declare -g -A INSTANCE_URL=()
}

test_case "freeze-recover: non-chrome instance → no-op"
reset_recover_state
INSTANCE_MODE[1]="vlc"
INSTANCE_URL[1]="http://frigate-restream-true.test:30059/?birdseye"
_maybe_auto_flip_chrome_via_jsmpeg_on_freeze 1
assert_eq "false" "$CHROME_VIA_JSMPEG"

test_case "freeze-recover: non-birdseye URL → no-op"
reset_recover_state
INSTANCE_URL[1]="http://example.com/dashboard"
_maybe_auto_flip_chrome_via_jsmpeg_on_freeze 1
assert_eq "false" "$CHROME_VIA_JSMPEG"

test_case "freeze-recover: CHROME_VIA_JSMPEG already true → no-op"
reset_recover_state
CHROME_VIA_JSMPEG="true"
INSTANCE_URL[1]="http://frigate-restream-true.test:30059/?birdseye"
_maybe_auto_flip_chrome_via_jsmpeg_on_freeze 1
assert_eq "true" "$CHROME_VIA_JSMPEG"

test_case "freeze-recover: operator explicitly set false → respect, no flip"
reset_recover_state
CHROME_VIA_JSMPEG_RESOLVED_REASON="operator-set-false"
INSTANCE_URL[1]="http://frigate-restream-true.test:30059/?birdseye"
_maybe_auto_flip_chrome_via_jsmpeg_on_freeze 1
assert_eq "false" "$CHROME_VIA_JSMPEG"

test_case "freeze-recover: chrome+birdseye + Frigate now restream:true → flip"
reset_recover_state
CHROME_VIA_JSMPEG_RESOLVED_REASON="frigate-restream-false"  # startup probe saw false; Frigate flipped since
INSTANCE_URL[1]="http://frigate-restream-true.test:30059/?birdseye"
_maybe_auto_flip_chrome_via_jsmpeg_on_freeze 1
assert_eq "true" "$CHROME_VIA_JSMPEG"
test_case "freeze-recover: flip records freeze-auto-recover reason"
assert_eq "freeze-auto-recover" "$CHROME_VIA_JSMPEG_RESOLVED_REASON"

test_case "freeze-recover: chrome+birdseye but Frigate still restream:false → no flip"
reset_recover_state
CHROME_VIA_JSMPEG_RESOLVED_REASON="frigate-restream-false"
INSTANCE_URL[1]="http://frigate-restream-false.test:30059/?birdseye"
_maybe_auto_flip_chrome_via_jsmpeg_on_freeze 1
assert_eq "false" "$CHROME_VIA_JSMPEG"

test_case "freeze-recover: chrome+birdseye + Frigate unreachable → no flip"
reset_recover_state
CHROME_VIA_JSMPEG_RESOLVED_REASON="frigate-probe-failed"
INSTANCE_URL[1]="http://frigate-down.test:30059/?birdseye"
_maybe_auto_flip_chrome_via_jsmpeg_on_freeze 1
assert_eq "false" "$CHROME_VIA_JSMPEG"

test_case "freeze-recover: startup-failed-probe + Frigate now reachable @ restream:true → flip"
# Most useful case: network blip at startup left us at frigate-probe-failed;
# operator's freeze is exactly the symptom that needs the shim.
reset_recover_state
CHROME_VIA_JSMPEG_RESOLVED_REASON="frigate-probe-failed"
INSTANCE_URL[1]="http://frigate-restream-true.test:30059/?birdseye"
_maybe_auto_flip_chrome_via_jsmpeg_on_freeze 1
assert_eq "true" "$CHROME_VIA_JSMPEG"

trap _summary EXIT
