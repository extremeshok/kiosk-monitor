# kiosk-monitor

Watchdog for kiosk-style displays. Launches Chromium in fullscreen kiosk mode **or** VLC against a video stream, then monitors the page/video for freezes and restarts automatically. Supports one or two displays at once, each running either Chromium or VLC independently.

![kiosk-monitor TUI walkthrough](docs/media/kiosk-monitor-demo.gif)

> Running Frigate? See [**docs/frigate-kiosk-guide.md**](docs/frigate-kiosk-guide.md)
> for a Frigate-focused install walk-through with built-in Birdseye smart defaults.

## Interactive configuration

Run `sudo kiosk-monitor` on the Pi with no arguments to open the
menu-driven editor — no hand-editing `kiosk-monitor.conf` required. The
menu covers both display instances, the Frigate helper, timing /
restart thresholds, logging, and **the systemd service itself**
(install, enable on boot, start, stop, restart, tail logs). Save +
Apply stays in the menu; Save + Exit leaves it.

| Main menu                          | Service submenu                        |
| ---------------------------------- | -------------------------------------- |
| ![Main menu](docs/media/main-menu.png) | ![Service submenu](docs/media/service-menu.png) |

| Instance editor                           | Frigate helper                             |
| ----------------------------------------- | ------------------------------------------ |
| ![Instance editor](docs/media/instance-edit.png) | ![Frigate helper](docs/media/frigate-menu.png) |

See [**docs/media/README.md**](docs/media/README.md) for how these
screenshots and the demo GIF are regenerated.

## Features
- **Two launch modes** per instance: `chrome` (fullscreen Chromium) or `vlc` (fullscreen video player).
- **Works on Wayland/labwc first, with X11 fallback retained** — detects labwc or a reachable X11 DISPLAY and picks the right capture + output tooling automatically.
- **Dual-display** support — tested end-to-end on **both Wayland (labwc) and X11** (Chromium on one HDMI + VLC RTSP on the other, both kiosk-fullscreen, both supervised independently). On Wayland the script writes an auto-generated labwc window rule (`MoveToOutput`) — Chromium matched by `identifier=` class, VLC by `title=`; both route reliably to the configured output. On X11 each instance is routed to its configured output after launch **and on every health-check tick** via `wmctrl` (drop fullscreen → move/resize to target rect → re-add fullscreen). The periodic re-check catches VLC's `--loop` behaviour of destroying and recreating its video window on every RTSP reconnect (which re-lands on the primary output); the check is idempotent so it's a silent no-op when placement is stable.
- **"Waiting for target" page** — when the configured kiosk URL isn't reachable at startup, Chromium launches a local HTML page that shows the target, a spinner, and the retry count; its JS polls the URL and auto-navigates once it responds. No more silent blank screens.
- **Per-output freeze detection** using `grim` (Wayland) or `import` / `maim` / `xwd` (X11): each instance is checked against its own monitor so a hang on one display never restarts the other. On X11 the watchdog crops to the instance's output rectangle when ImageMagick or `maim` is available, falling back to a whole-root capture if neither is.
- **Hardware video decode preserved** when the distro chromium ships VAAPI flags in `/etc/chromium.d/*`: kiosk-monitor parses those snippets, merges them with its own `--enable-features=` / `--disable-features=` additions, and emits one switch each — Chromium's parser is last-wins on repeated switches, so a bare set of our own would silently strip the distro's `VaapiVideoDecoder` enablement. The watchdog also adds `VaapiVideoDecoder`, `VaapiVideoEncoder`, and `VaapiVideoDecodeLinuxGL` to the merged enable list directly, so hardware decode survives even on Chromium builds that don't ship the distro snippets.
- **Kiosk-mode background throttling disabled** — `--disable-background-timer-throttling`, `--disable-renderer-backgrounding`, `--disable-backgrounding-occluded-windows`, plus `IntensiveWakeUpThrottling`, `BackForwardCache`, and `CalculateNativeWinOcclusion` in the disable-features list. Keeps JS timers, video pumps, and the page itself responsive even when the compositor's occlusion detection misfires on multi-monitor X11.
- **Autoplay-policy override** — `--autoplay-policy=no-user-gesture-required`. Without this, Chromium leaves an MSE-backed `<video>` paused after a buffer underrun until a user click "activates" the document, which on Frigate Birdseye showed up as the video grid freezing while the rest of the page kept rendering normally. Also disables `MediaSessionService` and `HardwareMediaKeyHandling` so two kiosks pointed at the same stream URL don't fight each other for the active media session.
- **Legacy i965 video-decoder workaround** — the watchdog detects whether libva is using the legacy `i965` driver (parsed from `vainfo`, with a DRI-driver-SO fallback when libva-utils isn't installed) and only on those boxes adds `UseChromeOSDirectVideoDecoder` to the disable-features list. Newer iHD / Mesa-VAAPI installs keep Chromium's preferred direct decoder path. The override is logged at launch (`VAAPI loaded via legacy i965 driver — disabling UseChromeOSDirectVideoDecoder`) so it's clear which path the kiosk took.
- **Doctor warning for the Chromium-on-i965 + Frigate Birdseye footgun** — `--doctor` flags the combination because Chromium 147's MSE pipeline freezes Birdseye after a few minutes on legacy-i965 hardware ([issue #1](https://github.com/extremeshok/kiosk-monitor/issues/1)) and the root cause is upstream Chromium, not anything kiosk-monitor's bash can patch. The warning recommends switching the affected instance to `MODE=vlc` with the go2rtc RTSP stream — `URL=rtsp://<frigate>:8554/birdseye` — which sidesteps Chromium's MSE pipeline entirely. Trade-off: loses Frigate's web-UI chrome, but the kiosk stays up.
- **URL health checks** for http/https targets, independent per instance.
- **Automatic restart** on frozen screens, dead processes, or repeated health failures, with per-instance storm-protection backoff.
- **Auto-detects the default desktop user** (active seat0 session → systemd autologin → lightdm autologin → SUDO_USER → first non-system UID).
- **Waits for the desktop to be open** before launching (Wayland compositor or X11 DISPLAY probed in sequence).
- **Self-install / update / remove** via `--install`, `--update`, `--remove`, `--reconfig`, `--configure` (interactive TUI), `--logs`, `--status`.
- **Interactive configuration TUI** (`whiptail`): run `sudo kiosk-monitor` from a terminal for a menu-driven editor of every supported option; all config is persisted in `/etc/kiosk-monitor/kiosk-monitor.conf`, so hand-editing the file is always an option too.
- **SIGHUP config reload** — `sudo systemctl reload kiosk-monitor` stops all instances, re-reads the config, and relaunches without a full restart.
- **Short-name launcher** — `/usr/local/bin/kiosk-monitor` (no `.sh`). No-arg invocation from a terminal opens the TUI; systemd uses `kiosk-monitor --run` to start the watchdog explicitly.
- Dedicated, isolated Chromium profiles per instance (no "restore previous session" prompts, no duplicate tabs).
- Optional tmpfs profile staging, prewarm, and periodic sync back to disk.
- Log rotation (copy-truncate) on `/dev/shm/kiosk.log`; configurable via `LOG_MAX_BYTES` / `LOG_ROTATE_KEEP`.

## Requirements
- **Raspberry Pi OS trixie 64-bit Desktop** (Debian 13) or newer — this is the minimum supported platform.
- Primary target: the stock labwc Wayland session on Raspberry Pi OS trixie Desktop. The X11 `rpd-x` session remains supported as a fallback.
- Needed packages: `chromium`, `vlc`, `curl`, `python3`, `sudo`, plus `grim` + `wlr-randr` on Wayland or `x11-apps` (xwd) + `x11-xserver-utils` (xset, xrandr) on X11; `whiptail` for the TUI. Anything missing is installed automatically by `--install` / `--update` via `apt-get`. Pass `--skip-apt` to opt out.
- **Recommended on multi-display X11:** install `imagemagick` (or `maim`) so the watchdog can crop the freeze-detection capture to each output. Without one of those installed the X11 path falls back to whole-root capture, which can't isolate a freeze on a single display when the other one is still moving.

## Quick install
```bash
curl -fsSL https://raw.githubusercontent.com/extremeshok/kiosk-monitor/main/kiosk-monitor.sh \
  | sudo bash -s -- --install --mode chrome --url "http://192.168.3.222:30059/?Birdseye"
```

Dual-display example (Chromium dashboard on primary, camera stream on secondary):
```bash
sudo kiosk-monitor --install \
  --mode chrome --url "http://192.168.3.222:30059/?Birdseye" --output HDMI-A-1 \
  --mode2 vlc   --url2 "rtsp://192.168.3.210:8554/cam1"       --output2 HDMI-A-2
```

The installer:
1. Auto-detects the desktop user (or use `--gui-user USER`).
2. Copies the script to `/usr/local/bin/kiosk-monitor` (and removes any pre-v6.2 `kiosk-monitor.sh` leftover there).
3. Creates `/etc/kiosk-monitor/kiosk-monitor.conf` (and a `.sample`).
4. Writes `/etc/systemd/system/kiosk-monitor.service` with `ExecStart=/usr/local/bin/kiosk-monitor --run` and the correct `User=`, `XDG_RUNTIME_DIR=`, `WAYLAND_DISPLAY=`.
5. Enables and starts the service (use `--no-start` to skip startup).

### Day-to-day commands
Running `kiosk-monitor` from an interactive terminal with no arguments opens the configuration TUI (pre-loaded with the current `kiosk-monitor.conf` values). Non-interactive callers (systemd, cron, scripts) must pass an explicit subcommand like `--run` — so piping the command at a daemon never silently starts the watchdog.

```bash
sudo kiosk-monitor                             # TUI (interactive terminal only; preloads current config)
sudo kiosk-monitor --run                       # watchdog (what systemd ExecStart uses)
sudo kiosk-monitor --logs                      # tail `journalctl -u kiosk-monitor -f` (supports --lines N / --no-follow / --all)
sudo kiosk-monitor --configure                 # same TUI, explicit
sudo kiosk-monitor --update --check            # show installed vs. latest GitHub version (no changes)
sudo kiosk-monitor --update                    # fetch latest from GitHub, install, restart if running
sudo kiosk-monitor --update --local            # install from the current working-tree file (dev mode)
sudo kiosk-monitor --update --force            # reinstall even when the remote matches
sudo kiosk-monitor --remove [--purge]          # remove binaries; --purge also drops /etc/kiosk-monitor
sudo kiosk-monitor --reconfig                  # re-write kiosk-monitor.conf with every supported option (alias: --reconfigure)
kiosk-monitor --status                         # show instance config + service status
kiosk-monitor --doctor                         # read-only environment/config diagnostics
kiosk-monitor --version
```
`--update` fetches `kiosk-monitor.sh` + `kiosk-monitor.conf.sample` from `$BASE_URL` (default `https://raw.githubusercontent.com/extremeshok/kiosk-monitor/HEAD`). Override with `--base-url URL` for forks or staging branches.

## Configuration — `/etc/kiosk-monitor/kiosk-monitor.conf`
Edit and then `sudo systemctl restart kiosk-monitor`.

### Minimum
| Variable   | Purpose                                                      | Default |
| ---------- | ------------------------------------------------------------ | ------- |
| `MODE`     | `chrome` or `vlc` for instance 1                             | `chrome` |
| `URL`      | Target page or stream for instance 1                         | Birdseye demo URL |
| `OUTPUT`   | Output name (e.g. `HDMI-A-1`); blank → auto                  | *(auto)* |
| `MODE2`    | `chrome`, `vlc`, or blank to disable instance 2              | *(disabled)* |
| `URL2`     | Target for instance 2                                        | *(empty)* |
| `OUTPUT2`  | Output name for instance 2; blank → auto                     | *(auto)* |
| `GUI_USER` | Desktop user; blank → auto-detect                            | *(auto)* |
| `FORCE_RESOLUTION` / `FORCE_RESOLUTION_2` | Force the instance's output to a specific mode (e.g. `1920x1080` or `1920x1080@60`). Applied via `wlr-randr` at startup and after hotplug. The call is skipped when the output already matches, to avoid fighting with `kanshi` and other output managers. Blank = leave alone. | *(blank)* |
| `FORCE_ROTATION` / `FORCE_ROTATION_2`     | Force the instance's output orientation. One of `normal`, `90`, `180`, `270`, `flipped`, `flipped-90`, `flipped-180`, `flipped-270`. | *(blank)* |

> **Note on output managers:** Raspberry Pi OS trixie Desktop autostarts `kanshi`, which observes output changes and can persist them to `~/.config/kanshi/config.init`. If a `FORCE_RESOLUTION` / `FORCE_ROTATION` change sticks across reboots even after you clear the variables, delete that file and respawn `wf-panel-pi` / `pcmanfm-pi` (or log out and back in).

Run `wlr-randr` as the desktop user to list available output names.

### Mode-specific
Chromium (`MODE=chrome`):
- `CHROMIUM_BIN` — path override (`/usr/bin/chromium` by default on trixie).
- `DEVTOOLS_AUTO_OPEN`, `DEVTOOLS_REMOTE_PORT` — debugging helpers.

Frigate helper (only matters when `MODE=chrome` points at a Frigate dashboard):
- **Smart defaults** — when the URL contains `?birdseye`, any Frigate helper variable left blank is filled in automatically: `FRIGATE_BIRDSEYE_AUTO_FILL=true`, `FRIGATE_DARK_MODE=Dark`, `FRIGATE_THEME="High Contrast"`. Set a variable to `None` (or `false` for the autofill toggle) to explicitly opt out.
- `FRIGATE_BIRDSEYE_AUTO_FILL` — `true` injects CSS that pins the Birdseye grid and canvas to explicit pixel dimensions so the react-grid-layout children scale with the container.
- `FRIGATE_BIRDSEYE_WIDTH` / `FRIGATE_BIRDSEYE_HEIGHT` — target size of the enlarged grid/canvas. Leave blank to auto-size from the instance's display resolution (via `wlr-randr`), so the same config works on 720p, 1080p, 1440p, 4K, or anything else. Set pixels to pin.
- `FRIGATE_BIRDSEYE_MARGIN` — pixels subtracted from each axis when auto-sizing (default `80`, leaves room for Frigate's sidebar and status bar).
- `FRIGATE_BIRDSEYE_MATCH_PATTERN` — override the extension match pattern (defaults to `scheme://host/*` from `URL`).
- `FRIGATE_BIRDSEYE_EXTENSION_DIR` — custom extension dir (default: under the profile).
- `FRIGATE_DARK_MODE` — `Light`, `Dark`, `None`, or empty (smart-default).
- `FRIGATE_THEME` — `Default`, `Blue`, `Green`, `Nord`, `Red`, `High Contrast`, `None`, or empty (smart-default).
- `FRIGATE_THEME_STORAGE_KEY` / `FRIGATE_COLOR_STORAGE_KEY` — override if your Frigate version uses different localStorage keys (defaults: `frigate-ui-theme` and `frigate-ui-color-scheme`; a handful of common aliases are also written).

Legacy `BIRDSEYE_*` config names still work (silently aliased).

VLC (`MODE=vlc`):
- `VLC_BIN` — path override (`/usr/bin/vlc` by default).
- `VLC_LOOP` (`true`/`false`), `VLC_NO_AUDIO` (`true`/`false`).
- `VLC_NETWORK_CACHING` — ms of network caching (raise for flaky RTSP).
- `VLC_EXTRA_ARGS` — free-form args appended to the VLC command line.

### Monitoring / timing
| Variable                | Description                                                     | Default |
| ----------------------- | --------------------------------------------------------------- | ------- |
| `HEALTH_INTERVAL`       | Watchdog loop interval (seconds)                                | `30` |
| `HEALTH_CONNECT_TIMEOUT`| curl connect timeout per probe (seconds)                        | `3` |
| `HEALTH_TOTAL_TIMEOUT`  | curl max time per probe (seconds)                               | `8` |
| `HEALTH_RETRIES`        | Consecutive failed http probes before restart                   | `6` |
| `STALL_RETRIES`         | Identical-frame hashes before restart (Chromium)                | `3` |
| `VLC_STALL_RETRIES`     | Identical-frame hashes before restart (VLC)                     | `6` |
| `SCREEN_DELAY`          | Seconds of runtime before freeze checks begin                   | `120` |
| `SCREEN_SAMPLE_MODE`    | `sample` (top-left 50%) or `full` frame                         | `sample` |
| `SCREEN_SAMPLE_BYTES`   | Byte-sampling fallback when image parsing fails                 | `524288` |
| `RESTART_WINDOW`        | Seconds the restart-rate ring buffer covers                     | `600` |
| `MAX_RESTARTS`          | Max restarts allowed within `RESTART_WINDOW` before backoff     | `10` |
| `CLEAN_RESET`           | Healthy-run seconds that reset the restart history              | `600` |

### Boot readiness
| Variable                 | Description                                                                  | Default |
| ------------------------ | ---------------------------------------------------------------------------- | ------- |
| `MIN_UPTIME_BEFORE_START`| Block until system uptime ≥ N seconds                                        | `60` |
| `GUI_SESSION_WAIT_TIMEOUT`| Max seconds to wait for a loginctl session to appear                        | `300` |
| `WAYLAND_READY_TIMEOUT`   | Max seconds to wait for `wayland-*` socket + labwc process                  | `300` |
| `SESSION_READY_DELAY`    | Extra seconds to pause after session is up                                   | `0` |
| `SESSION_READY_CMD`      | Optional command to poll until it returns 0                                  | *(unset)* |
| `SESSION_READY_TIMEOUT`  | Max seconds to wait for `SESSION_READY_CMD` (0 = forever)                    | `0` |
| `WAIT_FOR_URL`           | `true` uses the Chromium waiting page and blocks VLC http/https starts until the URL responds | `true` |
| `WAIT_FOR_URL_TIMEOUT`   | Seconds to wait for VLC's initial URL probe (0 = forever)                    | `0` |
| `CHROME_LAUNCH_DELAY`    | Seconds to sleep between spawning Chromium and resolving its main PID        | `3` |
| `CHROME_READY_DELAY`     | Seconds to sleep before looking up the main-browser PID                      | `2` |
| `VLC_LAUNCH_DELAY`       | Seconds to sleep between spawning VLC and resolving its PID                  | `3` |

### Profile / cache (Chromium)
| Variable                 | Description                                                                    | Default |
| ------------------------ | ------------------------------------------------------------------------------ | ------- |
| `PROFILE_ROOT`           | Profile parent dir (each chrome instance gets its own `chromium-N` subdir)     | `~/.local/share/kiosk-monitor` |
| `PROFILE_TMPFS`          | `true` stages profiles in RAM                                                  | `false` |
| `PROFILE_TMPFS_PATH`     | tmpfs profile root                                                             | `/dev/shm/kiosk-monitor` |
| `PROFILE_SYNC_BACK`      | `true` rsyncs the tmpfs profile back to disk on shutdown                       | `false` |
| `PROFILE_TMPFS_PURGE`    | `true` wipes the tmpfs profile on shutdown                                     | `false` |
| `PROFILE_ARCHIVE`        | Optional tar archive extracted into the profile before launch                  | *(unset)* |
| `PROFILE_SYNC_INTERVAL`  | Seconds between background tmpfs → disk syncs (0 disables)                     | `0` |
| `PREWARM_ENABLED`        | Pre-read browser binary/profile files into page cache before launch            | `true` |
| `PREWARM_PATHS`          | Colon-separated extra paths to prewarm                                         | *(unset)* |
| `PREWARM_MAX_FILES`      | Max files touched per path during prewarm                                      | `512` |
| `PREWARM_SLICE_SIZE`     | Bytes read from each file during prewarm                                       | `262144` |

## Runtime behaviour
- Logs go to stdout and `/dev/shm/kiosk.log` (override via `LOG=...`). Follow them live with `sudo kiosk-monitor --logs` or `journalctl -u kiosk-monitor -f`. The log file is copy-truncated once it exceeds `LOG_MAX_BYTES` (default 2 MiB); the previous copy is kept at `${LOG}.1` when `LOG_ROTATE_KEEP > 0`.
- Each Chromium instance runs with its own `--user-data-dir`, isolating cookies/session state. Chromium is launched with `--ozone-platform=wayland` on Wayland and `--ozone-platform=x11` on X11.
- VLC runs with `--intf=dummy` (no UI), `--fullscreen`, and a unique `--logfile` as a process fingerprint.
- Window placement is computed from `wlr-randr --json` on Wayland or `xrandr --query` on X11: each instance launches at its output's top-left with that output's native resolution, and the compositor fullscreens it to the containing monitor.
- Freeze detection uses `grim -o <OUTPUT>` on Wayland and prefers `import -window root -crop` (ImageMagick) → `maim -g` → `xwd -root` on X11. Each instance is compared against its own monitor's pixels, so a freeze on one display never restarts the other. On X11 multi-monitor setups without ImageMagick or `maim` installed, the watchdog falls back to a whole-root hash and logs a one-line debug hint — that fallback can't isolate a single-display freeze when the other display is still moving, so installing one of the two crop tools is recommended.
- Chromium launches with merged `--enable-features=` / `--disable-features=` switches: kiosk-monitor parses `/etc/chromium.d/*.conf`, `/etc/chromium-browser/default`, `/etc/chromium*/customizations/*`, and `~/.config/chromium-flags.conf` for any feature lists already configured by the distro, combines them with its own additions, and emits one switch each. Chromium's parser is last-wins on repeated switches, so a bare set of our own would silently strip the distro's `VaapiVideoDecoder` enablement on Debian/Ubuntu/Mint. The watchdog also adds `VaapiVideoDecoder`, `VaapiVideoEncoder`, and `VaapiVideoDecodeLinuxGL` to the merged enable list directly, so hardware decode survives even on Chromium builds that don't ship the distro snippets.
- Chromium also gets the kiosk-mode triplet (`--disable-background-timer-throttling`, `--disable-renderer-backgrounding`, `--disable-backgrounding-occluded-windows`) and `--autoplay-policy=no-user-gesture-required` unconditionally, plus `IntensiveWakeUpThrottling`, `BackForwardCache`, `CalculateNativeWinOcclusion`, `MediaSessionService`, and `HardwareMediaKeyHandling` in the merged disable list. The autoplay override is what unsticks Frigate Birdseye after MSE buffer underruns; without it Chromium leaves an MSE-backed `<video>` paused until a user gesture, with the rest of the page continuing to render normally.
- On systems where libva is using the legacy `i965` driver (Sandy Bridge through Coffee Lake Intel iGPUs) the watchdog also adds `UseChromeOSDirectVideoDecoder` to the merged disable list — the standard troubleshooting step when VAAPI playback misbehaves on Linux desktop, per the [Chromium VA-API doc](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/docs/gpu/vaapi.md) and [ArchWiki Hardware video acceleration](https://wiki.archlinux.org/title/Hardware_video_acceleration) page. Detection prefers `vainfo`, falling back to checking `/usr/lib/x86_64-linux-gnu/dri/` for the i965 driver SO file when libva-utils isn't installed. Newer iHD / Mesa-VAAPI installs keep the new direct decoder path. When the override fires, the launch line logs `VAAPI loaded via legacy i965 driver — disabling UseChromeOSDirectVideoDecoder`.
- Sending `SIGHUP` (via `sudo systemctl reload kiosk-monitor`) re-reads the config file, stops all instances, and relaunches. Editing the config file directly and reloading is always an option.

## Waiting page
When a Chromium instance's configured URL isn't reachable at launch time, `kiosk-monitor` generates `/tmp/kiosk-monitor-waiting-<id>.html` and points Chromium at that `file://` page instead of leaving the display blank or showing Chromium's error page. The page:
- shows the target URL prominently with a "Waiting for kiosk target" headline and a spinner;
- polls the target via `fetch(URL, { mode: 'no-cors' })` every 3 seconds in the browser (no bash involved);
- navigates to the real URL the moment the target responds (any response — 200, 302, 401, 500 — all count).

While the instance is on the waiting page the watchdog **does not** count health-probe failures against `HEALTH_RETRIES` and **does not** run freeze detection against the (intentionally static) page. Otherwise a target that stayed unreachable for more than a couple of minutes would trigger an endless "restart Chromium → relaunch waiting page → restart" loop, and the freeze detector would see the static page as a hung screen. Once the URL probe succeeds the log records `target <URL> now reachable — waiting page will redirect` and normal health + freeze supervision resumes.

Set `WAIT_FOR_URL=false` to disable the Chromium waiting page and launch directly at the configured URL even when the initial health probe fails. When enabled, the waiting page is only used if the target fails the initial probe. If the URL is reachable, Chromium launches directly at it with no indirection. The same flow applies when the watchdog restarts a chrome instance mid-run.

VLC instances still block on the old `wait_for_url_ready_instance` loop (no in-player equivalent); only Chromium gets the visual fallback.

## Cold-boot behaviour
The systemd unit is installed with the expectation that a freshly-booted Pi may take a minute or more before the desktop session is ready:
- `MIN_UPTIME_BEFORE_START=60` (config) — the script waits until system uptime reaches this before doing anything user-visible.
- `wait_for_display_ready` sits in a loop probing for a Wayland compositor (labwc / wayfire / sway / …) or a reachable X11 DISPLAY, logging `Waiting for a graphical session…` once and `Still waiting… (waited Ns)` every 60 s.
- `TimeoutStartSec=infinity` on the unit — systemd never kills the service mid-wait, no matter how long the desktop takes.
- `Restart=always`, `RestartSec=5`, `StartLimitIntervalSec=0`, `StartLimitBurst=0` — if the desktop never arrives the service exits 1 after `WAYLAND_READY_TIMEOUT` seconds (default 300) and systemd restarts it 5 s later, forever.

## Manual run / debugging
```bash
sudo LOG=/tmp/kiosk.log DEBUG=true /usr/local/bin/kiosk-monitor --run --debug
```
Press `Ctrl+C` to stop; systemd will relaunch if the service is enabled.

## systemd unit
`/etc/systemd/system/kiosk-monitor.service` (generated by the installer):
```ini
[Unit]
Description=Kiosk Monitor Watchdog (Chromium + VLC, dual-display)
Documentation=https://github.com/extremeshok/kiosk-monitor
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0
StartLimitBurst=0

[Service]
Type=simple
User=<detected desktop user>
Environment=GUI_USER=<detected desktop user>
Environment=XDG_RUNTIME_DIR=/run/user/<uid>
Environment=WAYLAND_DISPLAY=wayland-0
EnvironmentFile=-/etc/kiosk-monitor/kiosk-monitor.conf
ExecStart=/usr/local/bin/kiosk-monitor --run
ExecStop=/bin/kill -s TERM $MAINPID
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutStartSec=infinity
TimeoutStopSec=30
Restart=always
RestartSec=5
SyslogIdentifier=kiosk-monitor
StandardOutput=journal
StandardError=journal
SuccessExitStatus=0 130 143

[Install]
WantedBy=multi-user.target
WantedBy=graphical.target
```
Reload after any manual edit: `sudo systemctl daemon-reload`.

If `tailscaled.service` is enabled on the host, `--install`/`--update` automatically add `Requires=tailscaled.service` and include it in the `After=` chain.

## Frigate Birdseye auto-fill
For Chromium instances pointed at Frigate's Birdseye view, set `BIRDSEYE_AUTO_FILL=true`. The watchdog writes a minimal Chrome extension into the instance profile that injects CSS to force the grid and canvas to fill the viewport. Tune the selectors in `<PROFILE_ROOT>/chromium-<id>/birdseye-autofill/fullscreen.css` and re-run `--update` if you need a different layout.

## Example: freeze detection in action
```
2026-04-21 13:24:12 [1 chrome@HDMI-A-1] Launching Chromium on HDMI-A-1 (1920x1080+0+0) → http://192.168.3.222:30059/?Birdseye
2026-04-21 13:24:55 [1 chrome@HDMI-A-1] Chromium main PID=17258
2026-04-21 13:34:31 [1 chrome@HDMI-A-1] screen unchanged 1/3
2026-04-21 13:35:01 [1 chrome@HDMI-A-1] screen unchanged 2/3
2026-04-21 13:35:32 [1 chrome@HDMI-A-1] screen unchanged 3/3
2026-04-21 13:35:32 [1 chrome@HDMI-A-1] screen appears frozen — restarting
```
