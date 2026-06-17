# Turn a Raspberry Pi into a dedicated Frigate kiosk

*Camera wall on one screen, live stream on the other — auto-recovering,
survives reboots, no daily babysitting.*

![kiosk-monitor TUI](media/kiosk-monitor-demo.gif)

If you run **Frigate** and you want a wall-mounted display that Just
Shows The Cameras, this is for you. `kiosk-monitor` runs on a
Raspberry Pi (the stock **Raspberry Pi OS trixie 64-bit Desktop**),
launches Chromium in fullscreen pointed at your Frigate Birdseye
dashboard, and keeps it alive — across camera dropouts, network
blips, power outages, and HDMI hot-plugs.

On a Pi with two monitors, you can run the **Birdseye web UI on one
screen and a live RTSP stream on the other** — the same Pi, the same
service, two kiosks.

## Why not just set kiosk mode in Chromium?

Because kiosks in the wild fail in ways that aren't visible from the
browser:

- Frigate restarts → Chromium shows `ERR_CONNECTION_REFUSED` and stays
  stuck there until someone physically power-cycles the monitor.
- RTSP stream drops → VLC's video window disappears or re-opens on the
  wrong display.
- Cold boot → the Pi's Wayland compositor isn't ready when Chromium
  tries to open, so you get a black screen until someone logs in.
- The browser process *crashes silently* → you only find out when
  someone walks past and notices nothing is on the wall.

`kiosk-monitor` is the watchdog layer that catches all of those:

- **Per-display freeze detection** — if Chromium or VLC shows an
  identical frame for N ticks, it gets restarted. Each monitor is
  checked against its own pixels, so a hang on one display never
  restarts the other.
- **URL health checks** — probes the Frigate URL every 30 s; after N
  failures, restarts the browser pointed at it.
- **"Waiting for Frigate" page** — if Frigate isn't reachable on
  startup, Chromium shows a local page with a spinner and retry
  counter, then auto-navigates as soon as Frigate responds. No more
  blank black screens when the NVR boots slowly.
- **Desktop readiness** — waits for the Wayland compositor (labwc on
  stock Pi OS trixie) to be up before launching anything.
- **Per-instance restart storm-protection** — if a display keeps
  flapping, it's backed off for 5 minutes instead of thrashing.

## What it looks like on a dual-monitor rig

- HDMI-A-1 (1920×1080): **Chromium fullscreen** on
  `http://frigate.local:5000/?birdseye` with the built-in Frigate
  helper that auto-sizes the grid to the output and picks the
  high-contrast dark theme.
- HDMI-A-2 (1600×900): **VLC fullscreen** on an RTSP camera stream,
  auto-reconnecting with `--loop`.
- Both survive Frigate restarts, network blips, and unplug/replug
  events.
- A single `systemd` unit supervises both. Config reloads with
  `sudo systemctl reload kiosk-monitor` — no reboot.

## Install in 60 seconds

One command:

```bash
curl -fsSL https://raw.githubusercontent.com/extremeshok/kiosk-monitor/main/kiosk-monitor.sh \
  | sudo bash -s -- --install \
      --mode chrome --url 'http://frigate.local:5000/?birdseye' --output HDMI-A-1 \
      --mode2 vlc   --url2 'rtsp://user:pass@cam.local:554/cam'   --output2 HDMI-A-2
```

That's it. The installer:

1. Detects the desktop user (or take `--gui-user NAME`).
2. Writes `/etc/kiosk-monitor/kiosk-monitor.conf` and a systemd unit.
3. Enables + starts the service.

From then on:

```bash
sudo kiosk-monitor                # interactive TUI (see below)
sudo kiosk-monitor --logs         # tail journalctl for the service
sudo kiosk-monitor --status       # print current instance state
sudo kiosk-monitor --doctor       # read-only diagnostics
sudo kiosk-monitor --update       # pull the latest release
```

## The interactive menu

Run `sudo kiosk-monitor` from a terminal on the Pi and you get a
menu-driven editor for everything — no config-file hand-editing needed:

![Main menu](media/main-menu.png)

Each row is a category. `instance1` and `instance2` drive the two
displays; `frigate` fills in Birdseye-specific tweaks; `service`
manages the systemd unit itself (install, enable on boot, start,
stop, restart, tail logs):

![Service submenu](media/service-menu.png)

The instance editor is where most users will spend their time —
mode (chrome or vlc), URL, which HDMI output, forced resolution and
rotation if the monitor misidentifies itself:

![Instance editor](media/instance-edit.png)

And Frigate-specific knobs that make the Birdseye grid fill the
display properly:

![Frigate helper menu](media/frigate-menu.png)

When you save changes, the TUI offers to **apply them** in place —
it saves to `/etc/kiosk-monitor/kiosk-monitor.conf` and restarts the
service so the new config is live without leaving the menu.

## Frigate-specific smart defaults

If `URL` contains `?birdseye`, the Frigate helper turns on
automatically:

| Setting                            | Smart default          | What it does                                                   |
| ---------------------------------- | ---------------------- | -------------------------------------------------------------- |
| `FRIGATE_BIRDSEYE_AUTO_FILL`       | `true`                 | Pins the grid/canvas to the display size so cameras fill the screen. |
| `FRIGATE_DARK_MODE`                | `Dark`                 | Flips Frigate to dark mode the first time Chromium launches.  |
| `FRIGATE_THEME`                    | `High Contrast`        | High-contrast palette — great for wall displays at a distance. |
| `FRIGATE_BIRDSEYE_WIDTH/HEIGHT`    | auto from monitor res  | No manual pixel math per-display.                             |
| `FRIGATE_BIRDSEYE_MARGIN`          | `80`                   | Leaves room for Frigate's sidebar.                            |

Set any of those to `None` to explicitly opt out, or pin a value.

### When Birdseye freezes after a few minutes on Chromium

Symptom: the camera grid stops updating after 1–2 minutes, but the
sidebar thumbnails keep animating and the page is otherwise alive.
Clicking another view in the UI revives the stream for a few tens of
seconds before it freezes again. Two manual Firefox windows on the
same URL run cleanly.

This is [issue #1](https://github.com/extremeshok/kiosk-monitor/issues/1).
v6.11's CDP Media-domain re-diagnosis nailed the root cause:
Chromium 147's `ChunkDemuxer` reports `DEMUXER_UNDERFLOW` on a ~1 Hz
loop even while the `SourceBuffer` holds data ahead of `currentTime` —
the demuxer can't feed the decoder from its own buffered range and
eventually wedges. Reproduced on a Haswell i965 box (X11) AND on a
Pi 5 V3D (Wayland, no libva at all), so it isn't a VAAPI driver
quirk — it's Chromium's MSE pipeline against the fmp4 stream
Frigate's go2rtc emits when `birdseye.restream: true`. Earlier
versions of this guide blamed legacy-i965 and steered users at
VLC+RTSP; that workaround functioned but was a sidestep, not the fix.

You have three viable recipes, depending on which other clients you
need to keep working.

#### Recipe A — chrome-only kiosks: `birdseye.restream: false`

Simplest path. Edit Frigate's `config.yml`:

```yaml
birdseye:
  restream: false
```

Restart Frigate. Frigate's WebUI auto-selects its JSMpeg
canvas-over-WebSocket player for Birdseye when `restream` is false,
which doesn't touch Chromium's MSE pipeline at all. **Trade-off:**
the RTSP endpoint `rtsp://host:8554/birdseye` disappears. Per-camera
RTSP streams (`rtsp://host:8554/<camera_name>`) are unaffected.

#### Recipe B — keep RTSP and Chrome both working: `CHROME_VIA_JSMPEG=auto` (default)

This is the recipe v6.11 was built for. Keep Frigate at the canonical
`birdseye.restream: true` so VLC/HomeKit/etc. can still pull
`rtsp://host:8554/birdseye`. **Out of the box, kiosk-monitor v6.11
already does this**: `CHROME_VIA_JSMPEG=auto` (the default) probes each
chrome+birdseye instance's Frigate at startup, sees `restream: true`,
and automatically enables the extension's MSE-bypass shim. You can
verify with `kiosk-monitor --doctor` — it should report

> [ok] Chromium + Frigate Birdseye: extension JSMpeg shim active
>      (CHROME_VIA_JSMPEG=true) — MSE chunk-demuxer freeze bypassed

To force the shim on regardless of Frigate's setting, set
`CHROME_VIA_JSMPEG=true` (or `--chrome-via-jsmpeg` at install, or
toggle from the TUI under *Frigate helper → Chrome → JSMpeg (bypass
MSE)*.) To opt out of the auto-detect probe entirely (e.g. on networks
where Frigate isn't reachable from the kiosk), set
`CHROME_VIA_JSMPEG=false` and reach for Recipe A.

**Belt-and-braces auto-recovery:** the screen-freeze watchdog also
plays its part. If chrome ever shows the same frame for
`STALL_RETRIES` ticks on a Frigate Birdseye URL (the classic MSE
chunk-demuxer freeze symptom), kiosk-monitor re-probes Frigate
`/api/config`. If `restream:true` is now observed, it flips
`CHROME_VIA_JSMPEG=true` in-memory and the imminent restart
regenerates the extension with the shim active. This catches the two
cases the startup probe can't see: (1) the operator flipped
`birdseye.restream` to `true` after kiosk-monitor started without
sending it a SIGHUP, and (2) the startup probe failed (network blip
or Frigate cold-boot) but Frigate is genuinely at `restream:true`.
Operator-set `CHROME_VIA_JSMPEG=false` is always respected — the
freeze still triggers a normal restart but the shim isn't
auto-enabled against the operator's opt-out. When the
chrome target URL is a Frigate Birdseye view (`?birdseye` or
`#birdseye`), the kiosk-monitor Chromium extension drops a
`world: "MAIN"` content script that intercepts the page's
`/api/config` fetch + XHR responses and rewrites `birdseye.restream`
to `false` before Frigate's React app reads them. Frigate's
`LiveBirdseyeView` then takes its native JSMpeg branch, mounting a
canvas player against Frigate's already-running
`/live/jsmpeg/birdseye` WebSocket. Chromium's MSE pipeline is never
invoked — the freeze can't happen. The operator sees the full Frigate
WebUI (camera labels, sidebar, click-to-zoom); only the player swaps.

End-to-end verified on the Pi 5 viewport against a real Frigate
0.17.1-416a9b7 at 192.168.3.222: with `birdseye.restream: true`
server-side and `CHROME_VIA_JSMPEG=true` on kiosk-monitor, the page
mounts a single 1920×1080 `<canvas>` painting frames and zero
`<video>` elements. VLC simultaneously plays `rtsp://.../birdseye`
without interference.

**Caveat:** every `/api/config` response the WebUI sees has
`birdseye.restream` rewritten to `false`. Any UI control that toggles
behaviour on `restream` reads the patched value. For a wall-display
kiosk with no operator interaction that's invisible; if you also use
that same browser session as an interactive Frigate console, prefer
Recipe A.

#### Recipe C — VLC instead of Chrome

If you don't need Frigate's WebUI chrome (camera labels, sidebar,
click-to-zoom) and just want the camera wall, point VLC at the RTSP
stream directly:

```ini
MODE="vlc"
URL="rtsp://<frigate-host>:8554/birdseye"
# or, if go2rtc is Docker-mapped to a non-standard port:
# URL="rtsp://<frigate-host>:30060/birdseye"
```

`sudo kiosk-monitor --discover-streams http://<frigate>:port` prints
a copy-pasteable list of the actual stream names + ports configured on
your Frigate, plus a one-line snippet you can paste into
`kiosk-monitor.conf`. The discover output also flags your current
`birdseye.restream` setting and recommends the right recipe (A, B,
or C) for your workflow.

#### When the VLC camera wall flashes grey, then footage returns

The restreamed birdseye (a go2rtc `libx264 -tune zerolatency` re-encode of
`/tmp/cache/birdseye`) delivers frames with an uneven cadence. VLC's PCR
arrives "late", it grows `pts_delay` (default `--clock-jitter` is 5000ms) and
periodically **resets its reference clock** to the stream's RTCP clock — the
reset stops frame output for a beat and the display goes solid grey until it
re-locks. The tell in `/tmp/kiosk-monitor-vlc-<id>.log`:

```
ES_OUT_SET_(GROUP_)PCR is called too late (pts_delay increased to … ms)
buffer deadlock prevented
Timestamp conversion failed … no reference clock
Could not get display date for timestamp 0
```

`ffmpeg -rtsp_transport tcp -i <url> -t 60 -f null -` decoding the same stream
cleanly for 60s (no discontinuities) confirms the feed is fine and the fault is
VLC's RTSP clock handling.

Since **v6.12.0** kiosk-monitor hardens live-stream URLs automatically
(`VLC_RTSP_HARDENING=auto`): `--clock-jitter=0` (stop the `pts_delay` runaway),
`--clock-synchro=0` (free-run on VLC's own clock instead of resetting to the
stream's — kills the grey flash), `--rtsp-tcp`, and a 1500ms
`--network-caching` jitter buffer. All overridable via `VLC_EXTRA_ARGS`; set
`VLC_CLOCK_SYNCHRO=-1` to restore VLC's default if the added latency bothers
you on a low-latency wall.

Source-side complement (optional): set `birdseye.idle_heartbeat_fps` to a small
non-zero value so the stream keeps emitting frames during idle stretches and
never goes quiet in the first place.

#### Why the obvious "manual go2rtc.streams entry" doesn't work

If you've read Frigate's docs you might be tempted to keep
`birdseye.restream: false` AND add a manual `go2rtc.streams.birdseye-rtsp`
entry. This is a dead end, save the next operator the debugging time.
Frigate's `output/birdseye.py` gates the named pipe `/tmp/cache/birdseye`
on `birdseye.restream: true` — with `restream: false`, the pipe
doesn't exist, so any custom RTSP exporter pointed at it produces no
frames. We tried it, it fails predictably. Recipe B (above) is the
working "have both" path.

#### Why simply deleting `window.MediaSource` from the extension doesn't help on 0.17.1

The first instinct for the extension-side fix was to delete
`window.MediaSource` and let Frigate's feature-detection fall back to
JSMpeg. Frigate 0.17.1 actually falls back to **WebRTC**, not JSMpeg,
when `MediaSource in window` is false (see
`web/src/views/live/LiveBirdseyeView.tsx` around line 119). WebRTC
sidesteps MSE but needs ICE-candidate negotiation that often fails on
internal-only networks. Recipe B above takes the
`config.birdseye.restream === false → "jsmpeg"` branch instead, which
is the only path to JSMpeg in 0.17.1, by patching the WebUI's view of
the config rather than the global object.

`kiosk-monitor --doctor` flags chrome + Frigate Birdseye combinations
and prints the same recommendations, so any future operator who hits
this can self-serve from the diagnostic output. When
`CHROME_VIA_JSMPEG=true` is already set on a matching instance, the
doctor reports OK.

## Supervisor details (skip unless you care)

- Built-in health loop runs every `HEALTH_INTERVAL` seconds (default
  30 s). Screen freeze checks start after `SCREEN_DELAY` seconds
  (default 120 s) to skip the legitimate black screen during launch.
- Log rotation: `/dev/shm/kiosk.log` is copy-truncated when it exceeds
  `LOG_MAX_BYTES` (default 2 MiB). Journald sees every line too.
- Profile can live in tmpfs for SD-card longevity (`PROFILE_TMPFS=true`).
- Tailscale-aware: if `tailscaled.service` is enabled, the kiosk-monitor
  unit gets `Requires=` on it so the VPN is up before Chromium tries
  to resolve a `*.ts.net` Frigate URL.

## Dual-display tested end-to-end

Dual-display is tested on **both labwc Wayland and X11**. On Wayland
the script drops a labwc window rule at install time so Chromium
(matched by `--class`) and VLC (matched by `--video-title`) both land
on the correct output. On X11 each instance is positioned directly via
`--window-position` / `--window-size`, re-verified via `wmctrl` on
every health-check tick so that VLC's `--loop` recreate-on-reconnect
doesn't pull the window back onto the primary output.

## One-line uninstall

```bash
sudo kiosk-monitor --remove --purge    # also drops /etc/kiosk-monitor
```

## Source + issues

GitHub: <https://github.com/extremeshok/kiosk-monitor>

If something doesn't work on your Pi model or your Frigate setup,
file an issue with:
- `sudo kiosk-monitor --version`
- `sudo kiosk-monitor --status`
- `sudo kiosk-monitor --logs --lines 200 --no-follow`
