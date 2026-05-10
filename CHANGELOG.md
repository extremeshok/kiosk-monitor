# Changelog

All notable changes to kiosk-monitor are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [6.9.3] — 2026-05-10

### Fixed
- `--doctor` summary line now reflects warnings + errors emitted by
  `validate_runtime_config`. Before this fix, `Config warning:` /
  `Config error:` lines from the validator printed straight to stderr
  without ever touching the doctor's `$warnings` / `$errors`
  counters, so the final `Doctor summary: N error(s), M warning(s)`
  reported 0 / 0 even when validate had flagged real issues. Surfaced
  by [issue #1](https://github.com/extremeshok/kiosk-monitor/issues/1)
  reporter on v6.9.2: their `--doctor` correctly printed two
  `Config warning:` lines from v6.9.0's MODE=vlc + HTTP-URL guard but
  the summary said "0 error(s), 0 warning(s)". `_doctor_check_runtime_config`
  now captures validate's stderr, re-emits each `Config warning:` /
  `Config error:` line through `doctor_warn` / `doctor_error` (which
  count toward the summary), and passes non-classified lines through
  verbatim. New `tests/test_doctor_accounting.sh` (4 cases) replays
  the reporter's exact misconfig from a fixture and asserts the
  summary line now counts the validator's findings.

## [6.9.2] — 2026-05-10

### Added
- VLC / Chromium connect-grace gate: the watchdog's stall counter no
  longer ticks toward the freeze threshold until it has observed a
  hash transition (evidence the player rendered something different
  from its initial frame). Protects against the failure mode where a
  player pointed at an unreachable stream sits on a uniform black
  window and the kiosk restart-loops a player that's working as
  designed but waiting on the network. Implemented via new per-instance
  `INSTANCE_FIRST_FRAME_SEEN` state, reset in `setup_instances` and
  `record_restart_instance`. Diagnostic log lines on debug level when
  the gate engages and when stall ticks are suppressed.
- `tests/test_connect_grace.sh`: 9 cases that replay the watchdog
  stall-detection branch as a standalone tick function and verify
  the state machine's behaviour across uniform-frame runs, hash
  transitions, mid-stall recovery, delayed-connect scenarios, and
  structural state-array declarations.

### Fixed
- Shellcheck SC2218 forward-reference (error level): v6.9.1 introduced
  `prepare_runtime_state`, `relaunch_all_instances`, and
  `reload_instances` after their first call sites. Moved the three
  definitions to live above the inline startup block.
- Shellcheck SC2086 at `set -- $geo` in `resolve_output_geometry`:
  intentional word-splitting of a single space-separated string,
  annotated with rationale + `# shellcheck disable=SC2086`.
- Shellcheck SC2015 in the TUI quit-confirm shortcut: rewrote
  `A && B || C` as explicit if/else for unambiguous semantics.

### Changed
- CI workflow now runs the bash test harness (`tests/run.sh`) on every
  push and PR, in addition to the existing `bash -n` + `shellcheck`
  steps.
- `CONTRIBUTING.md` documents the test harness, the local check
  recipe, and the verified-platform matrix.

## [6.9.1] — 2026-05-10

Structural refactor (Groups B + C from the post-v6.9.0 audit). No
user-visible behaviour change — the freeze-investigation behaviour
from v6.8.x is preserved exactly; this pass cleans up the script's
internal organisation.

### Added
- `main_init()` consolidates the post-config-load setup
  (`apply_frigate_smart_defaults`, `FRIGATE_BIRDSEYE_AUTO_FILL` fixup,
  `normalize_config_values`, MODE/MODE2 sanity checks) into one
  function defined and invoked after every helper has been declared.
  Eliminates the function-ordering trap that bit v6.8.8.
- `prepare_runtime_state()` and `relaunch_all_instances()` extract
  the post-config-load setup sequence and instance-relaunch loop that
  were duplicated between the inline `--run` startup block and
  `reload_instances`. Both call sites now reduce to two-line
  orchestration.
- `build_chrome_flags()` (passes the flags array via bash 4.3+
  nameref) and `resolve_chrome_launch_url()` extract the 100-line
  flag-array construction and 20-line URL/waiting-page selection out
  of `launch_chrome_instance`, which shrinks from 160 lines to 51.
- `_doctor_check_*` decomposition: the 129-line `doctor_self`
  monolith is now nine named check functions (`_doctor_check_config_file`,
  `_doctor_check_runtime_config`, `_doctor_check_required_commands`,
  `_doctor_check_chromium_binary`, `_doctor_check_vlc_binary`,
  `_doctor_check_desktop_user`, `_doctor_check_graphical_session`,
  `_doctor_check_outputs_and_mapping`, `_doctor_check_i965_birdseye_footgun`)
  plus a 25-line orchestrator. `doctor_ok / doctor_warn /
  doctor_error` remain defined inside `doctor_self`; the extracted
  checks see them via bash dynamic scoping.
- `tests/` directory with a minimal pure-bash test harness:
  `tests/lib.sh` (assertions + `load_function` + `run_kiosk`),
  `tests/run.sh` (aggregating runner), `tests/fixtures/` (distro
  Chromium + minimal kiosk-monitor configs), and four test files
  covering URL detection, JS-string escaping, Chromium feature-list
  merging, and subprocess integration. 48 cases at v6.9.1.

## [6.9.0] — 2026-05-10

Group A correctness pass. Three small low-risk fixes from the
v6.8.x freeze investigation.

### Added
- `js_escape()` helper next to `regex_escape` — escapes a value for
  splicing into a JS double-quoted string literal. Replaces five
  duplicated `sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'` pipelines in
  `ensure_frigate_extension` and `write_waiting_page`.
- `_url_looks_like_media_for_vlc` heuristic and `_validate_instance_url`
  helper inside `validate_runtime_config`: when `MODE=vlc` and `URL`
  is `http(s)://something-that-doesn't-look-like-media`, the validator
  emits a warning naming the failure mode (VLC sits idle, watchdog
  declares it frozen, restart-loops) and points users at the right
  URL shape. Catches the issue #1 reporter's mis-config where they
  swapped `MODE=vlc` but left `URL` pointed at Frigate's HTML page.

### Fixed
- Shellcheck SC2020 in `merge_chromium_features`: replaced
  `tr ',[:space:]' '\n\n'` (implementation-defined when source/dest
  char-class lengths differ — GNU/BSD pad, BusyBox doesn't) with
  `awk -v RS='[,[:space:]]+'` for unambiguous splitting across all
  tr variants. Was a real cross-platform risk for Alpine, OpenWrt,
  and other minimal distros.

## [6.8.9] — 2026-05-09

### Removed
- `FRIGATE_LIVE_MODE` and `FRIGATE_LIVE_STORAGE_KEY` config vars,
  `apply_frigate_live_mode_default` resolver, and the live-mode
  localStorage seed in the helper extension JS (introduced in v6.8.8).
  Verified against a live Frigate instance that Birdseye's player
  choice is hardcoded server-side from `birdseye.restream` config —
  there's no client-side localStorage override for it. The seed wrote
  keys Frigate doesn't read. Replacing with documentation honesty.

### Added
- `--doctor` warning that fires when `chromium_vaapi_uses_legacy_i965`
  returns true *and* any instance has `MODE=chrome` on a Frigate
  Birdseye URL. Recommends `MODE=vlc` with the go2rtc RTSP stream as
  the workaround that actually works on the affected hardware combo
  (Sandy Bridge through Coffee Lake Intel iGPUs hitting the upstream
  Chromium-MSE freeze in issue #1). Also notes the Frigate-side
  alternative (`birdseye.restream: false`) for users who need to
  keep the web UI.

## [6.8.8] — 2026-05-09 (superseded by v6.8.9)

Attempted to pre-seed Frigate's "Preferred Live Mode" via localStorage
from the helper extension. The model was wrong for current Frigate;
fully reverted in v6.8.9. Listed for completeness; no users should
deploy this version.

## [6.8.7] — 2026-05-09

### Added
- `chromium_vaapi_uses_legacy_i965` detector: parses `vainfo` output
  for `Intel i965 driver`, falls back to checking
  `/usr/lib/x86_64-linux-gnu/dri/i965_drv_video.so` presence when
  libva-utils isn't installed. Cached on first call.
- `UseChromeOSDirectVideoDecoder` is now added to the merged disable-
  features list **only** on hardware where libva loaded the legacy
  i965 driver (Sandy Bridge through Coffee Lake Intel iGPUs).
  Newer iHD / Mesa-VAAPI installs keep Chromium's preferred direct
  decoder path.

### Changed
- v6.8.6 had blanket-disabled the feature for everyone; v6.8.7 gates
  it on the i965 detector.

## [6.8.5] — 2026-05-08

### Added
- `--autoplay-policy=no-user-gesture-required`: addresses the issue
  #1 symptom where MSE-backed `<video>` stalls after buffer underruns
  and Chromium's autoplay policy refuses to resume without a user
  gesture (visible as "page alive, sidebar GIFs animating, only the
  video grid frozen").
- `MediaSessionService` and `HardwareMediaKeyHandling` added to the
  merged disable-features list — defensive, prevents two kiosks
  pointed at the same stream from fighting over the active media
  session.

## [6.8.4] — 2026-05-08

### Fixed
- v6.8.3's `merge_chromium_features` correctly merges the distro's
  `--enable-features=` / `--disable-features=` from `/etc/chromium.d/*`
  with kiosk-monitor's additions. Reporter's `ps` output confirms
  the merged enable list now contains `VaapiVideoDecoder`,
  `VaapiVideoEncoder`, `VaapiVideoDecodeLinuxGL`, and
  `UseChromeOSDirectVideoDecoder` alongside `OverlayScrollbar` and
  `UseOzonePlatform` — Chromium 147 reports `Video Decode: Hardware
  accelerated` in `chrome://gpu`.

## [6.8.3] — 2026-05-08

Three fixes addressing the freeze symptom in
[#1](https://github.com/extremeshok/kiosk-monitor/issues/1):

### Added
- Helper to read the distro Chromium wrapper's feature flags
  (`/etc/chromium.d/*.conf`, `/etc/chromium-browser/default`,
  `/etc/chromium*/customizations/*`, `~/.config/chromium-flags.conf`)
  and merge them with kiosk-monitor's additions before launch.
  Chromium's command-line parser is last-wins on repeated switches,
  so a bare `--enable-features=…` of our own would silently strip
  the distro's VAAPI enablement.
- Kiosk-mode background-throttling triplet:
  `--disable-background-timer-throttling`,
  `--disable-renderer-backgrounding`,
  `--disable-backgrounding-occluded-windows`. Plus
  `IntensiveWakeUpThrottling`, `BackForwardCache`, and
  `CalculateNativeWinOcclusion` in the merged disable-features
  list. Keeps JS timers and video pumps responsive when the
  compositor's occlusion detection misfires on multi-monitor X11.
- `capture_output_hash` X11 path now crops to the per-output
  rectangle. Tries `import -window root -crop` (ImageMagick), then
  `maim -g`, falling back to `xwd -root` when neither crop tool is
  installed. Closes the long-standing comment that admitted any
  motion on either display reset the freeze counter on multi-monitor
  X11.

## [6.8.2] — 2026-05-07

### Fixed
- Dropped `--width`, `--height`, `--video-x`, `--video-y` from the
  VLC launch flags. They didn't size the window — they enforced the
  video output buffer dimensions, which suppressed VLC's autoscale
  and rendered a 1080p RTSP source at native size in the top-left
  quadrant of a 4K display. Window placement is already handled
  post-launch by labwc rules + `route_window_to_output_x11` /
  wmctrl. Verified on a 4K Hisense TV with 1080p RTSP mosaic
  filling 3840×2160.

## [6.8.1] — 2026-04-24

### Fixed
- Frigate-helper extension JS had `setAll(THEME_ALIASES, DARK)` /
  `setAll(COLOR_ALIASES, THEME)` — wrote "dark" into theme keys
  and the theme name into colour keys. Swapped to the correct
  `setAll(THEME_ALIASES, THEME)` / `setAll(COLOR_ALIASES, DARK)`.
- Various kiosk-hardening fixes (config quoting via `quote_config_value`,
  `WAIT_FOR_URL` gating of the waiting-page launch, labwc-rules
  handling for single-instance configs that pin OUTPUT explicitly,
  `--doctor` subcommand introduced).

## [6.8.0] — 2026-04-23

### Added
- Interactive service-management submenu in the TUI (install, enable
  on boot, start, stop, restart, tail logs).
- Dual-display Wayland verified end-to-end on labwc.

## [6.7.0] — 2026-03-21

### Added
- Dual-display X11 routing via wmctrl (drop fullscreen → move/resize
  to target output rect → re-add fullscreen), reasserted on every
  health-check tick to catch VLC's `--loop` window recreation.

## [6.6.0] — 2026-03-15

### Added
- "Waiting for target" page replaces silent URL wait. Chromium
  launches a local HTML page that polls the configured URL and
  navigates to it as soon as it responds.

## Older

See the git log for v6.0.0 → v6.5.0 release notes (TUI, --run
subcommand, X11 fallback support, smart Wayland wait, etc.).
