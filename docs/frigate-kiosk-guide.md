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

### When Birdseye freezes after a few minutes on Chromium (legacy Intel iGPUs)

Symptom: the camera grid stops updating after 1–2 minutes, but the
sidebar thumbnails keep animating and the page is otherwise alive.
Clicking another view in the UI revives the stream for a few tens of
seconds before it freezes again. Two manual Firefox windows on the
same URL run cleanly.

This is Chromium 147's MSE pipeline misbehaving on Intel iGPUs that
fall back to libva's legacy `i965` driver — Sandy Bridge through
Coffee Lake (the issue surfaced on a Haswell-era Dell 3020 in
[issue #1](https://github.com/extremeshok/kiosk-monitor/issues/1)).
Hardware decode is engaged (`chrome://gpu` confirms `Video Decode:
Hardware accelerated`), but the MSE state machine stalls after
buffer underruns and Chromium's autoplay policy refuses to resume
without a user gesture. There's no clean kiosk-monitor-side fix
because Birdseye's player is decided server-side from Frigate's
`birdseye.restream` config — there's no localStorage-backed user
preference to override client-side.

**The recommended workaround is to skip Chromium entirely for the
Birdseye view and feed VLC the go2rtc RTSP stream:**

```ini
# /etc/kiosk-monitor/kiosk-monitor.conf
MODE="vlc"
URL="rtsp://<frigate-host>:8554/birdseye"
# or, if go2rtc is on a non-standard port:
# URL="rtsp://<frigate-host>:30060/birdseye"
```

VLC's RTSP path doesn't touch Chromium's MSE pipeline at all, runs
cleanly under software or hardware decode, and is what kiosk-monitor
already uses for camera-only displays. Trade-off: you lose the
Frigate web-UI chrome (camera labels, the event-thumbnails sidebar,
click-to-zoom), and gain a kiosk that stays up. For a wall display
showing live cameras only, that's almost always the right swap.

**Find the right RTSP URLs with `--discover-streams`:**

```bash
# Point it at your Frigate web URL (whatever was in URL=…):
sudo kiosk-monitor --discover-streams http://192.168.1.194:30059
# or at standalone go2rtc:
sudo kiosk-monitor --discover-streams http://192.168.1.194:30060
```

Output is a copy-pasteable list of the actual stream names + ports
configured on your Frigate, plus a one-line `MODE=vlc` / `URL=…`
snippet for `kiosk-monitor.conf`. `kiosk-monitor --doctor` also
runs this automatically when the VLC + HTTP-URL guard fires, so a
single `--doctor` pass shows both the diagnosis and the concrete
fix.

`kiosk-monitor --doctor` flags this hardware combination and prints
the same recommendation, so any future user who hits it can self-
serve from the diagnostic output.

If you specifically need the Frigate web UI on a wall display, the
alternative is to set `birdseye.restream: false` in Frigate's
`config.yml` — that flips Frigate to the JSMpeg canvas-over-WebSocket
player for Birdseye, which doesn't touch MSE. That change is
server-side and affects every Frigate client, not just the kiosk.

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
