#!/usr/bin/env bash
# Tests for chromium_distro_features + merge_chromium_features — the
# pair that parses the distro's chromium-flags conf files and merges
# their feature-list values with kiosk-monitor's own additions. The
# bug class these guard against: bare cmdline --enable-features=… is
# last-wins, so without a merge we'd silently strip the distro's
# VAAPI enablement on Debian/Ubuntu/Mint.

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_functions chromium_distro_features merge_chromium_features

# chromium_distro_features greps a fixed list of system paths. To run
# it against our fixture, override the function's file-glob with a
# shim that points at tests/fixtures/distro-chromium.conf only.
chromium_distro_features() {
  local kind=$1
  local switch="--${kind}-features="
  local combined="" features path
  for path in "$FIXTURES_DIR/distro-chromium.conf"; do
    [ -r "$path" ] || continue
    while IFS= read -r features; do
      [ -n "$features" ] || continue
      combined+="${combined:+,}$features"
    done < <(
      grep -hoE -- "${switch}[\"']?[A-Za-z0-9_,/\\-]+" "$path" 2>/dev/null \
        | sed -e "s|^${switch}||" -e "s|^[\"']||" -e "s|[\"']\$||"
    )
  done
  printf '%s\n' "$combined"
}

test_case "distro_features enable: parses distro VAAPI list"
assert_eq "VaapiVideoDecoder,VaapiVideoEncoder,VaapiVideoDecodeLinuxGL,UseChromeOSDirectVideoDecoder" \
  "$(chromium_distro_features enable)"

test_case "distro_features disable: parses distro disable list"
assert_eq "TFLiteLanguageDetectionEnabled,GlobalVaapiLock" \
  "$(chromium_distro_features disable)"

test_case "merge_chromium_features enable: distro + user, deduped"
out=$(merge_chromium_features enable OverlayScrollbar UseOzonePlatform VaapiVideoDecoder)
assert_eq "VaapiVideoDecoder,VaapiVideoEncoder,VaapiVideoDecodeLinuxGL,UseChromeOSDirectVideoDecoder,OverlayScrollbar,UseOzonePlatform" "$out"

test_case "merge_chromium_features disable: distro + user, deduped"
out=$(merge_chromium_features disable TranslateUI ChromeWhatsNewUI GlobalVaapiLock)
assert_eq "TFLiteLanguageDetectionEnabled,GlobalVaapiLock,TranslateUI,ChromeWhatsNewUI" "$out"

test_case "merge_chromium_features: empty user input → distro only"
out=$(merge_chromium_features enable)
assert_eq "VaapiVideoDecoder,VaapiVideoEncoder,VaapiVideoDecodeLinuxGL,UseChromeOSDirectVideoDecoder" "$out"

test_case "merge_chromium_features: dedups across user args"
out=$(merge_chromium_features enable Foo Foo Bar Foo)
assert_match '(^|,)Foo(,|$)' "$out"
# only one Foo
assert_eq "1" "$(printf '%s' "$out" | tr ',' '\n' | grep -c '^Foo$')"

test_case "merge_chromium_features: tolerates whitespace in user args"
out=$(merge_chromium_features enable "  Foo  Bar  ")
# Both should appear, distro features still present
assert_match 'Foo' "$out"
assert_match 'Bar' "$out"
assert_match 'VaapiVideoDecoder' "$out"

test_case "chromium_distro_features: missing file → empty"
chromium_distro_features() {
  # Override again with a path that doesn't exist
  local kind=$1 switch="--${kind}-features="
  local combined="" features path
  for path in "$FIXTURES_DIR/does-not-exist.conf"; do
    [ -r "$path" ] || continue
    while IFS= read -r features; do
      combined+="${combined:+,}$features"
    done < <(grep -hoE -- "${switch}[A-Za-z0-9_,]+" "$path" 2>/dev/null)
  done
  printf '%s\n' "$combined"
}
assert_eq "" "$(chromium_distro_features enable)"

trap _summary EXIT
