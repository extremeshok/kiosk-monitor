# Changelog

All notable changes to kiosk-monitor are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [6.12.0] — 2026-06-17

### Fixed

- Intermittent "feed drops to the bare desktop for minutes, then recovers on
  its own" on a dual-display kiosk, even though the HDMI link never physically
  dropped (no kernel hotplug event). Root cause was a false-negative in the
  watchdog's output detection: `refresh_outputs` cleared `OUTPUTS_NAMES` up
  front, so a single transient `wlr-randr`/`python3` failure (an IPC hiccup, or
  a compositor reload provoked by the relaunch-time labwc SIGHUP) left the list
  empty. The caller (`refresh_outputs || true`) read that as "every output
  disconnected", so `instance_output_present` returned false and the instance
  was paused — VLC killed, desktop wallpaper shown — until a later poll happened
  to succeed. There was no debounce (one bad tick paused) and no cap on how long
  the paused state could persist.
- Fix, three complementary layers:
  - `refresh_outputs` (both the wlr-randr and xrandr paths) is now
    non-destructive on failure: it builds into locals and only commits to
    `OUTPUTS_NAMES`/`OUTPUT_GEOMETRY` on a trustworthy, non-empty reading. A
    transient poll failure returns non-zero and leaves the last-known-good list
    intact instead of blanking it.
  - `instance_output_present` consults the kernel's DRM connector status
    (`/sys/class/drm/card*-<output>/status`) as ground truth when wlr-randr
    doesn't list the output. If the connector still reads `connected`, the
    output is treated as present — a compositor/wlr-randr stall can no longer
    fake a disconnect. No-op when output and DRM connector names differ.
  - The pause gate is debounced via the new `OUTPUT_MISS_GRACE` (default 3):
    the requested output must read absent on that many consecutive ticks
    (≈ `OUTPUT_MISS_GRACE` × `HEALTH_INTERVAL` seconds) before the instance is
    paused. The instance keeps running normally during the grace window.
- Intermittent "grey screen, then footage returns" on a VLC RTSP feed. A
  restreamed Frigate birdseye (go2rtc re-encode) delivers frames with an uneven
  cadence — during idle stretches the producer emits few/no frames, so VLC's
  PCR arrives "late" and it keeps growing `pts_delay` (the default
  `--clock-jitter` window is 5000ms) until it loses the reference clock and
  stops painting. The output shows a solid grey until frames resume. VLC logged
  the signature repeatedly: `ES_OUT_SET_(GROUP_)PCR is called too late
  (pts_delay increased to …)`, `buffer deadlock prevented`,
  `no reference clock`, `Could not get display date for timestamp 0`.
- Fix: live-stream hardening is now applied automatically (see *Added* /
  `VLC_RTSP_HARDENING`). For `rtsp/rtsps/rtmp/rtmps/udp` URLs the launcher now
  passes `--clock-jitter=0` (disables the `pts_delay` runaway),
  `--clock-synchro=0` (free-run on VLC's own clock instead of periodically
  resetting to the stream's RTCP reference clock — that reset is what flashes
  the screen grey; verified against a structurally-clean source that `ffmpeg`
  decodes for 60s with zero discontinuities while VLC still loses its reference
  clock ~once a minute), `--rtsp-tcp` for `rtsp/rtsps` (reliable transport;
  go2rtc serves `rtsp+tcp`), and a default `--network-caching` jitter buffer.
  All overridable. Optionally pair with the Frigate-side
  `birdseye.idle_heartbeat_fps` (a small non-zero value) to keep frames flowing
  during idle.

### Changed

- `VLC_STALL_RETRIES` default raised from 6 to 20. A live RTSP camera/mosaic
  (e.g. Frigate birdseye at low motion) legitimately renders byte-identical
  frames for long stretches; at 6 ticks (~3 min) the screen-hash watchdog
  mistook that for a wedged decoder and restart-looped VLC, flicking the screen
  to the desktop roughly once a day. 20 ticks (~10 min of truly unchanging
  output) still catches a genuinely frozen decoder while no longer firing on
  idle cameras. Pair with Frigate birdseye `mode: continuous` to eliminate the
  static-frame condition at the source.
- VLC live streams now default to a 1500ms network cache
  (`VLC_NETWORK_CACHING_DEFAULT`) when `VLC_NETWORK_CACHING` is unset. An
  explicit `VLC_NETWORK_CACHING` still takes precedence, and anything in
  `VLC_EXTRA_ARGS` is appended last and overrides the hardening defaults.

### Added

- `OUTPUT_MISS_GRACE` config knob (default 3) — consecutive missed output polls
  required before pausing an instance whose display is reported gone.
- `VLC_RTSP_HARDENING` (default `auto`) — apply VLC live-stream hardening for
  `rtsp/rtsps/rtmp/rtmps/udp` URLs (`auto`), always (`true`), or never
  (`false`).
- `VLC_CLOCK_JITTER` (default `0`) — VLC `--clock-jitter` value applied by the
  hardening; `0` disables the `pts_delay` growth that ends in a grey-out.
- `VLC_CLOCK_SYNCHRO` (default `0`) — VLC `--clock-synchro` value applied by the
  hardening; `0` free-runs on VLC's own clock (no grey clock-reset), `-1`
  restores VLC's default, `1` forces synchronization on.
- `VLC_NETWORK_CACHING_DEFAULT` (default `1500`) — network cache used for live
  streams when `VLC_NETWORK_CACHING` is unset.
- `tests/test_output_presence.sh` — regression coverage for the non-destructive
  `refresh_outputs` and the `instance_output_present` DRM-status fallback.
- `tests/test_vlc_flags.sh` — coverage for the VLC live-stream hardening flag
  builder (auto-detection by URL scheme, override precedence, opt-out).

## [6.11.2] — 2026-05-12

### Fixed

- vlc+vlc dual-display window routing. v6.11.1's `reload_labwc_window_rules`
  sent a bare SIGHUP to labwc — but labwc 0.9.x only re-evaluates window
  rules against already-mapped surfaces when it detects rc.xml has
  *changed*. A bare SIGHUP on unchanged content is a no-op. Result: with
  two VLC instances on a single Pi 5 (one per HDMI), both VLC windows
  could end up stacked on HDMI-A-1 with HDMI-A-2 stuck on the desktop
  wallpaper — vlc-2's late-arriving `xdg_toplevel.set_title` meant the
  initial-map rule check found an empty title and the window stayed on
  the default output.
- Fix: `reload_labwc_window_rules` now rewrites rc.xml with a fresh
  `<!-- kiosk-monitor: relayout-nudge: TIMESTAMP -->` line *before*
  SIGHUP, so labwc sees the file as changed and re-applies all
  `windowRule` actions against currently-mapped surfaces. The rule body
  is unchanged — only the nudge comment differs — so the rewrite is
  idempotent. Empirically verified on the viewport3 Pi 5: 5/5
  consecutive `systemctl restart kiosk-monitor` cycles with vlc+vlc
  now place each VLC on its target output, with continuous video
  observed on both displays.
- Added a second `reload_labwc_window_rules` call at the end of
  `relaunch_all_instances` — runs after every instance has had its
  per-launch `VLC_LAUNCH_DELAY` settle, catching the dual-VLC case
  where the first VLC's late-arriving title can land its window on the
  second VLC's target output. The per-instance call inside
  `launch_vlc_instance` continues to handle single-VLC watchdog
  restarts.

### Changed

- `reload_labwc_window_rules` rewrites rc.xml via a single
  `printf | grep -v | as_gui tee` pipeline instead of two `sed -i`
  invocations. The pipeline is portable across BSD and GNU sed (the
  script targets Linux but the test suite runs on macOS) and avoids a
  brief window where rc.xml exists without the new marker between the
  two prior sed-delete-then-sed-insert calls.
- Added `KIOSK_LABWC_RC_XML` env-var override on `reload_labwc_window_rules`
  for test-only path injection. Defaults to the production path
  (`/home/$GUI_USER/.config/labwc/rc.xml`); unused outside tests.

### Added

- `tests/test_labwc_reload.sh` — 11 assertions covering the v6.11.2 fix:
  X11 short-circuit (no file/SIGHUP touch), missing rc.xml (SIGHUP still
  fires), unmanaged rc.xml (no marker → file untouched), managed rc.xml
  (relayout-nudge inserted at top), idempotency (N calls → exactly ONE
  marker, file size bounded), fresh timestamps across calls, and
  pkill-invocation shape (SIGHUP, -u GUI_USER, -x labwc). Catches both
  the v6.11.1 regression (bare SIGHUP) and future marker-accumulation
  bugs in the dedupe path.

### Validated

- Full 5-config dual-display test matrix on the viewport3 Pi 5 with two
  physically distinct monitors (Dell S2421HGF + Hisense): chrome+vlc,
  chrome+chrome, vlc+vlc (3/3 restart stress-test BOTH-LIVE),
  single-display chrome (HDMI-A-2 wallpaper untouched), single-display
  vlc (HDMI-A-2 wallpaper untouched). All five PASS.

## [6.11.1] — 2026-05-12

### Fixed

- Dual-display labwc window-routing race. VLC's xdg_toplevel sometimes
  maps before `xdg_toplevel.set_title("kiosk-monitor-vlc-N")` arrives,
  so labwc's `<windowRule title="…">` evaluates at map time and misses
  — leaving VLC on the default output (HDMI-A-1) and covering the
  Chromium kiosk. Surfaced on the viewport3 Pi 5 after a stress
  sequence of rapid service restarts: most launches routed correctly,
  one in ~5 raced and landed VLC on the wrong display.
- Fix: after `VLC_LAUNCH_DELAY` (default 3 s) elapses — by which time
  the title is reliably set — `launch_vlc_instance` SIGHUPs labwc to
  re-evaluate window rules against the now-titled surface. New helper
  `reload_labwc_window_rules` keeps the SIGHUP behind a Wayland guard
  so X11 sessions are a no-op. Stale "VLC runs under Xwayland" comment
  in `ensure_labwc_window_rules` updated to reflect the actual
  Wayland-native path.

## [6.11.0] — 2026-05-11

Closes the longest-running issue in this project: the Frigate Birdseye
freeze on Chromium kiosks (#1). v6.11 is built on a definitive
re-diagnosis via Chromium DevTools Protocol Media-domain instrumentation
and an empirical pass through every plausible recipe on a live
Frigate 0.17.1 instance. Root cause and two viable remediation paths
are baked into code, docs, and the `--doctor` / `--discover-streams`
advisory output.

### Root cause (re-confirmed)

The freeze symptom (page alive, Birdseye video frozen, sidebar
animations still moving) was previously attributed to libva-i965 +
VAAPI quirks (v6.8.7). The CDP Media-domain trace shows the actual
mechanism: Chromium 147's `ChunkDemuxer` reports `DEMUXER_UNDERFLOW` in
a ~1 Hz loop while the `SourceBuffer` still holds data ahead of
`currentTime`. The demuxer can't feed the decoder from its own buffered
range, the pipeline wedges, and the renderer stays stuck on the last
decoded frame. Reproduced on hardware as different as Pi 5 V3D
(Wayland, no libva) and Haswell i965 (X11). This rules out a
VAAPI-stack origin; the bug is in Chromium's MSE pipeline against the
fmp4 stream go2rtc emits when Frigate runs with `birdseye.restream: true`.

### Added

- **`CHROME_VIA_JSMPEG` config knob (tristate: `auto` / `true` /
  `false`; default `auto`; `--chrome-via-jsmpeg`,
  `--no-chrome-via-jsmpeg`, `--auto-chrome-via-jsmpeg` install flags).**
  When effectively `true` AND a chrome instance points at a Frigate
  Birdseye URL, the existing kiosk-monitor Chromium extension grows a
  second content-script entry — `force-jsmpeg.js`, running in
  `world: "MAIN"` at `document_start` — that intercepts the page's
  `fetch()` and `XMLHttpRequest` responses for `/api/config` and
  rewrites `birdseye.restream` to `false` before Frigate's React app
  reads it. Frigate's `LiveBirdseyeView.tsx` then takes its
  `restream === false → "jsmpeg"` branch, mounting Frigate's own
  JSMpeg canvas player. MSE is never invoked, so the chunk-demuxer
  freeze can't trigger. Server-side config is untouched —
  `rtsp://host:8554/birdseye` keeps working for VLC/HomeKit in
  parallel.
- **Auto-detect (`CHROME_VIA_JSMPEG=auto`, the default).** During
  `prepare_runtime_state` (so also on SIGHUP reload), kiosk-monitor
  probes each chrome+birdseye instance's Frigate `/api/config` for
  `birdseye.restream`. If any matching Frigate reports `restream:true`,
  the shim auto-enables; if all report `false`, the shim stays off
  (Frigate's WebUI picks JSMpeg natively at that setting, no freeze
  risk); if probes fail, the shim stays off and the doctor warns the
  operator to investigate. `--doctor` distinguishes all four outcomes
  with context-aware messages. Operator can override with
  `CHROME_VIA_JSMPEG=true|false` to skip the probe.
- **Freeze-detection auto-recovery.** Reactive safety net for the
  cases the startup probe can't see: the operator flipped Frigate to
  `birdseye.restream:true` *after* the watchdog started, or the
  startup probe failed (network blip, Frigate cold-boot) and we
  defaulted to off. When the existing screen-freeze watchdog detects
  a stalled chrome+birdseye instance, kiosk-monitor re-probes Frigate
  `/api/config`; if `restream:true` is now observed, it flips
  `CHROME_VIA_JSMPEG="true"` in-memory (the operator's on-disk config
  isn't touched) and the imminent chrome relaunch regenerates the
  extension with the force-jsmpeg.js shim active. `--doctor` reports
  this with a distinct `freeze-auto-recover` reason. Explicit
  `CHROME_VIA_JSMPEG=false` (operator opt-out) is always respected —
  the freeze still triggers a normal restart but the shim is never
  auto-enabled against the operator's setting.
- Empirically verified end-to-end against a live Frigate
  0.17.1-416a9b7 running on the Pi 5 viewport3 fleet:
    * With `birdseye.restream: true` server-side and
      `CHROME_VIA_JSMPEG=auto` on kiosk-monitor, auto-detect logs
      "enabling JSMpeg shim", the page mounts a single 1920×1080
      `<canvas>` and the JSMpeg player paints frames from
      `/live/jsmpeg/birdseye`. Doctor reports "extension JSMpeg shim
      active — MSE chunk-demuxer freeze bypassed".
    * With `birdseye.restream: false` (the older recipe), auto-detect
      logs "WebUI picks JSMpeg natively, no freeze risk" and the
      doctor reports OK without any shim.
    * With the flag explicitly off and `restream:true`, the same page
      mounts `<video>` (MSE) and freezes as before — the doctor warns
      the operator.
- `is_frigate_birdseye_url()` now also matches the `#birdseye` hash
  route (Frigate's React WebUI uses that natively). The previous
  `?birdseye` and `&birdseye` matchers are retained.
- `--remote-allow-origins=*` is now passed automatically whenever
  `DEVTOOLS_REMOTE_PORT` is set. Chromium 147 enforces remote origin
  allow-listing by default, breaking DevTools CDP attach without it.
  Discovered during the v6.11 diagnostic work.
- TUI gains a "Chrome → JSMpeg (bypass MSE)" toggle under the Frigate
  helper menu, with the current state surfaced on the main-menu
  summary line. `--status` also reports `chrome-via-jsmpeg`.
- TUI gains a "Run read-only diagnostic checks (--doctor)" entry on the
  main menu. Forks the same `--doctor` the CLI runs and shows the
  output in a whiptail msgbox so operators don't have to drop to a
  shell to read the resolved CHROME_VIA_JSMPEG state, the screen-output
  map, the validate-config breadcrumbs, etc. If the TUI has unsaved
  edits when invoked, it offers to Save first so the probe reflects
  what would actually run on the next service restart.
- `--discover-streams` now reads `birdseye.enabled` and
  `birdseye.restream` from Frigate's `/api/config` and emits a NOTE
  guiding the operator to one of the two viable paths
  (`restream: false` for chrome-only, or `CHROME_VIA_JSMPEG=true` for
  chrome + VLC).

### Changed

- `--doctor` chrome-on-Frigate-Birdseye check rewritten. Was scoped to
  legacy i965 VAAPI hardware and recommended VLC + RTSP as the
  primary remediation. Now fires on `chrome + Frigate Birdseye`
  regardless of hardware (it's a Chromium MSE issue, not a VAAPI one)
  and recommends the two viable fixes by name. When
  `CHROME_VIA_JSMPEG=true` is already set on a matching instance, the
  check reports OK instead of warning.

### Fixed

- Removed the i965 → `--disable-features=UseChromeOSDirectVideoDecoder`
  conditional introduced in v6.8.7. Live testing on Pi 5 V3D showed
  forcing that disable made the freeze *faster*, and
  `--disable-accelerated-video-decode` made the renderer stop at the
  first frame. The original v6.8.7 reasoning was based on the
  now-disproven VAAPI hypothesis.

### Docs

- New "Have both Chrome AND VLC on /birdseye?" section in the Frigate
  kiosk guide, with the two viable recipes side-by-side and the two
  dead-end approaches documented (so the next operator who tries the
  obvious "manual `go2rtc.streams.birdseye-rtsp` entry" finds an
  explanation of why it can't work without patching Frigate's source).
- README updated with the new flag and recipe summary.

### Tests

- New `tests/test_jsmpeg.sh` (28 cases): force-jsmpeg.js generation
  (fetch+XHR overrides, /api/config scope, restream rewrite, MIT
  attribution preserved), manifest assembly (world:MAIN entry, two-
  entry case when autofill is also on, match pattern carry-through),
  and auto-resolver behaviour (operator-set passthrough, restream:true
  → enable, restream:false → no-op, probe failure handling, mixed-
  target precedence). The auto-resolver tests use a `curl` shim to
  serve canned Frigate responses, so they run offline.
- `tests/test_discover_streams.sh` extended (now 49 cases): three new
  cases covering the birdseye-restream NOTE, plus a fresh fixture
  (`frigate-api-config-birdseye-restream-false.json`).
- `tests/test_url_detection.sh` extended (now 22 cases) for the new
  `#birdseye` hash-route matcher.
- `tests/lib.sh` `load_function` extractor made brace+heredoc-aware so
  larger functions (notably ensure_frigate_extension, which emits CSS
  and JSON heredocs with single-"}" lines) can be loaded for testing.
  Previously the extractor exited on the first heredoc-internal "}".
- Freeze-detection auto-recovery tests (9 cases): the no-op gates
  (non-chrome, non-birdseye, already-true, operator-set-false), the
  flip cases (Frigate now restream:true; startup probe failed but
  Frigate now reachable), and the safe-no-flip cases (Frigate still
  restream:false, Frigate unreachable).
- Total harness: 151 cases across 8 files (up from 99 in v6.10.3).

## [6.10.3] — 2026-05-10

### Added
- TUI integration for `--discover-streams`. Main menu gains a
  "Discover Frigate / go2rtc RTSP streams" entry; choosing it walks
  the operator through:
    1. Frigate (or go2rtc) URL prompt — defaulting to whatever HTTP
       URL is already configured on either instance.
    2. Optional RTSP port override (for Dockerised Frigate where
       external port ≠ go2rtc internal `:8554`).
    3. Probe via `discover_frigate_streams`. Full output (banner,
       port source, Docker port-mapping NOTE, credentials NOTE,
       stream list) is shown in a whiptail msgbox so the operator
       sees the same diagnostic context they'd see at the command
       line.
    4. On success, radiolist of discovered RTSP URLs.
    5. Instance picker (1 / 2 / cancel) that sets `MODE=vlc` + URL
       on the chosen instance and marks the TUI dirty so the
       standard Apply / Save flows write the change to
       `kiosk-monitor.conf`.
  Nothing irreversible without confirmation; cancel paths return
  to the main menu without mutating state. Surfaced via four new
  structural tests (function declared, menu entry present,
  dispatch case branch, delegation to `discover_frigate_streams`).
  Total harness: 103 cases.

## [6.10.2] — 2026-05-10

### Added
- `--discover-streams` now extracts `go2rtc.rtsp.username` and
  `go2rtc.rtsp.password` from Frigate's `/api/config` and embeds
  them (percent-encoded) in the suggested RTSP URLs. Without this,
  the operator copies a stream URL that fails to authenticate
  against Frigate's go2rtc when auth is configured. Live-tested
  against the viewport3 fleet's production Frigate where
  `URL2="rtsp://admin:123456@.../birdseye"` was the working URL —
  v6.10.2 now produces that shape automatically.
- New NOTE in the discovery output when credentials are embedded,
  reminding the operator that `kiosk-monitor.conf` is sensitive
  (root-owned but stores credentials in plaintext).
- `tests/fixtures/frigate-api-config-with-rtsp-auth.json` +
  three new test cases (credentials embedded, NOTE printed,
  no-creds output unchanged). 99 cases total in the harness.

## [6.10.1] — 2026-05-10

Surfaced by live-testing v6.10.0 against the production Frigate
served by the Pi 5 viewport3 fleet — and the production setup the
issue #1 reporter is on.

### Added
- `--discover-streams` now probes `<url>/api/go2rtc/streams` *first*
  (before `/api/config` and `/api/streams`). This is the
  Frigate-proxied go2rtc runtime-streams endpoint. It surfaces
  streams that Frigate auto-generates from its config but never
  writes to the static `go2rtc.streams` block — most importantly,
  Birdseye when `birdseye.restream: true` triggers an internal
  ffmpeg pipeline. v6.10.0 against a real Frigate reported
  "no streams configured" even though `rtsp://host/birdseye` was a
  working stream; v6.10.1 reports `rtsp://host:8554/birdseye`
  correctly.
- `--discover-streams URL --rtsp-port N` flag override. For
  Dockerised Frigate the externally-reachable RTSP port is typically
  mapped (e.g. `:30060` external → `:8554` internal) and differs
  from the `go2rtc.rtsp.listen` value reported by Frigate's
  `/api/config`. The override lets operators paste the correct
  external port without editing Frigate's config.
- Docker port-mapping NOTE in the discovery output. Fires when:
  Frigate web is on a non-default port (i.e. not `:5000` —
  signalling Docker port-mapping is in play), AND the RTSP port we
  found via `go2rtc.rtsp.listen` is the default `:8554`, AND
  `--rtsp-port` wasn't passed. Tells the operator how to find the
  external mapped port (`docker compose port frigate 8554`) so they
  don't try a `rtsp://host:8554` URL that the host firewall rejects.

### Changed
- Discovery output now annotates the RTSP port with its source —
  one of `--rtsp-port override`, `go2rtc.rtsp.listen in Frigate
  config (internal)`, or `default (go2rtc)` — so the operator can
  tell at a glance whether the suggested URL is likely to work
  externally.
- Detection banner specifies which probe matched, e.g.
  `Frigate detected at host:5000 (via /api/go2rtc/streams)` vs
  `Frigate detected at host:5000 (via /api/config; /api/go2rtc/streams unavailable)`.
- Empty-streams hint adds a pointer to `birdseye.restream: true`
  for users who want Birdseye exposed.

### Fixed
- `set -u` gotcha: `cfg_body` was only assigned in the
  frigate-proxy branch but referenced unconditionally afterwards.
  Now declared with an explicit `=""` default.

### Tests
- `tests/test_discover_streams.sh` expanded from 10 to 15 cases.
  New fixtures `frigate-api-go2rtc-streams.json` and
  `frigate-api-go2rtc-streams-birdseye-only.json` cover the
  frigate-proxy probe path including the issue-#1 "auto-generated
  Birdseye only" shape. Total harness: 95 cases.

## [6.10.0] — 2026-05-10

Minor bump because of the new user-facing subcommand. No breaking
changes; all existing flags / behaviour preserved.

### Added
- `kiosk-monitor --discover-streams URL` subcommand: probes a Frigate
  or go2rtc HTTP endpoint and prints the actual RTSP stream URLs
  available, plus a copy-pasteable `MODE=vlc` / `URL=…` snippet for
  `kiosk-monitor.conf`. Probes `<url>/api/config` first (Frigate's
  config endpoint — yields `go2rtc.streams` + `go2rtc.rtsp.listen`
  for the port); falls back to `<url>/api/streams` (standalone
  go2rtc). RTSP port is parsed from `go2rtc.rtsp.listen` (handles
  `:8554`, `tcp://:8554`, `0.0.0.0:8554`); defaults to `8554` when
  unset. Exit codes: 0 = streams found, 1 = endpoint unreachable or
  empty, 2 = usage error.
- `--doctor` auto-discovery: when the VLC + HTTP-URL guard fires
  (instance with `MODE=vlc` pointed at an HTTP web page that doesn't
  look like a media stream), the doctor now follows up by running
  `discover_frigate_streams` against the URL inline. Operator sees
  the actual RTSP candidates underneath the warning, not a generic
  `rtsp://<frigate>:8554/birdseye` placeholder. Each unique URL is
  probed at most once per `--doctor` invocation. `validate_runtime_config`
  itself stays synchronous so script startup doesn't hang on a slow
  Frigate.
- `tests/test_discover_streams.sh` with 10 cases driven by a curl
  shim and four JSON fixtures (`frigate-api-config.json` default,
  `…-rtsp-tcp` for the `tcp://0.0.0.0:9999` listen form,
  `…-no-streams` for empty go2rtc.streams, `go2rtc-api-streams.json`
  for the standalone-go2rtc path). Covers: Frigate path with
  default + alternate RTSP port, sorted output, copy-paste snippet
  shape, empty-streams hint, go2rtc-direct fallback, unreachable
  host error, missing-URL usage error, trailing-slash robustness.
  Total harness: 83 cases.

### Changed
- `--help` text and the top-of-file usage block document the new
  subcommand. `kiosk-monitor.bash-completion` includes
  `--discover-streams` in the action list.

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
