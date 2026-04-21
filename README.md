# kiosk-monitor

Watchdog for kiosk-style displays. Launches Chromium in fullscreen kiosk mode **or** VLC against a video stream, then monitors the page/video for freezes and restarts automatically. Supports one or two displays at once, each running either Chromium or VLC independently.

## Features
- **Two launch modes** per instance: `chrome` (fullscreen Chromium) or `vlc` (fullscreen video player).
- **Works on Wayland or X11** — detects labwc/wayfire/sway/… or an X11 DISPLAY and picks the right capture + output tooling automatically.
- **Dual-display** support (**experimental**) — Chromium can be routed to specific outputs via a generated labwc window rule; VLC routing is unreliable because its Wayland window identity isn't easily matched. Single-instance (one display) is the supported configuration today.
- **"Waiting for target" page** — when the configured kiosk URL isn't reachable at startup, Chromium launches a local HTML page that shows the target, a spinner, and the retry count; its JS polls the URL and auto-navigates once it responds. No more silent blank screens.
- **Per-output freeze detection** using `grim` (Wayland) or `xwd` (X11): each instance is checked against its own monitor so a hang on one display never restarts the other.
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
- Either a Wayland compositor (labwc on the stock trixie Desktop) **or** an X11 session (e.g. LightDM's `rpd-x`). Both are auto-detected.
- Needed packages: `chromium`, `vlc`, `curl`, `python3`, `sudo`, plus `grim` + `wlr-randr` on Wayland or `x11-apps` (xwd) + `x11-xserver-utils` (xset, xrandr) on X11; `whiptail` for the TUI. Anything missing is installed automatically by `--install` / `--update` via `apt-get`. Pass `--skip-apt` to opt out.

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
kiosk-monitor --version
```
`--update` fetches `kiosk-monitor.sh` + `kiosk-monitor.conf.sample` from `$BASE_URL` (default `https://raw.githubusercontent.com/extremeshok/kiosk-monitor/main`). Override with `--base-url URL` for forks or staging branches.

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
| `WAIT_FOR_URL`           | `true` blocks each http/https instance until its URL responds                | `true` |
| `WAIT_FOR_URL_TIMEOUT`   | Seconds to wait for the initial URL probe (0 = forever)                      | `0` |
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
- Freeze detection uses `grim -o <OUTPUT>` on Wayland or `xwd -root` on X11; on Wayland each instance is compared against its own monitor, on X11 against the whole root (single-display setups).
- Sending `SIGHUP` (via `sudo systemctl reload kiosk-monitor`) re-reads the config file, stops all instances, and relaunches. Editing the config file directly and reloading is always an option.

## Waiting page
When a Chromium instance's configured URL isn't reachable at launch time, `kiosk-monitor` generates `/tmp/kiosk-monitor-waiting-<id>.html` and points Chromium at that `file://` page instead of leaving the display blank or showing Chromium's error page. The page:
- shows the target URL prominently with a "Waiting for kiosk target" headline and a spinner;
- polls the target via `fetch(URL, { mode: 'no-cors' })` every 3 seconds in the browser (no bash involved);
- navigates to the real URL the moment the target responds (any response — 200, 302, 401, 500 — all count).

No configuration toggle: the waiting page is only used when the target fails the initial health probe. If the URL is reachable, Chromium launches directly at it with no indirection. The same flow applies when the watchdog restarts a chrome instance mid-run.

VLC instances still block on the old `wait_for_url_ready_instance` loop (no in-player equivalent); only Chromium gets the visual fallback.

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
After=network-online.target graphical.target
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
ExecStart=/usr/local/bin/kiosk-monitor.sh
ExecStop=/bin/kill -s TERM $MAINPID
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
