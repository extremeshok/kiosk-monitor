# kiosk-monitor

Watchdog for kiosk-style displays. Launches Chromium in fullscreen kiosk mode **or** VLC against a video stream, then monitors the page/video for freezes and restarts automatically. Supports one or two displays at once, each running either Chromium or VLC independently.

## Features
- **Two launch modes** per instance: `chrome` (fullscreen Chromium) or `vlc` (fullscreen video player).
- **Dual-display** support — run Chromium on HDMI-A-1 and VLC on HDMI-A-2 (or any combination) from a single watchdog.
- **Per-output freeze detection** using `grim`: each instance is checked against its own monitor so a hang on one display never restarts the other.
- **URL health checks** for http/https targets, independent per instance.
- **Automatic restart** on frozen screens, dead processes, or repeated health failures, with per-instance storm-protection backoff.
- **Auto-detects the default desktop user** (active seat0 session → systemd autologin → lightdm autologin → SUDO_USER → first non-system UID).
- **Waits for the desktop to be open** before launching (labwc process + `wayland-*` socket).
- **Self-install / update / remove** via `--install`, `--update`, `--remove`, `--reconfig`, `--status`.
- Dedicated, isolated Chromium profiles per instance (no "restore previous session" prompts, no duplicate tabs).
- Optional tmpfs profile staging, prewarm, and periodic sync back to disk.

## Requirements
- **Raspberry Pi OS trixie 64-bit Desktop** (Debian 13) or newer — this is the minimum supported platform.
- Wayland (labwc compositor — default on trixie desktop).
- Preinstalled on the stock image: `chromium`, `vlc`, `grim`, `wlr-randr`, `curl`, `python3`, `sudo`.

## Quick install
```bash
curl -fsSL https://raw.githubusercontent.com/extremeshok/kiosk-monitor/main/kiosk-monitor.sh \
  | sudo bash -s -- --install --mode chrome --url "http://192.168.3.222:30059/?Birdseye"
```

Dual-display example (Chromium dashboard on primary, camera stream on secondary):
```bash
sudo kiosk-monitor.sh --install \
  --mode chrome --url "http://192.168.3.222:30059/?Birdseye" --output HDMI-A-1 \
  --mode2 vlc   --url2 "rtsp://192.168.3.210:8554/cam1"       --output2 HDMI-A-2
```

The installer:
1. Auto-detects the desktop user (or use `--gui-user USER`).
2. Copies the script to `/usr/local/bin/kiosk-monitor.sh`.
3. Creates `/etc/kiosk-monitor/kiosk-monitor.conf` (and a `.sample`).
4. Writes `/etc/systemd/system/kiosk-monitor.service` with the correct `User=`, `XDG_RUNTIME_DIR=`, `WAYLAND_DISPLAY=`.
5. Enables and starts the service (use `--no-start` to skip startup).

### Update / remove / reconfigure
```bash
sudo kiosk-monitor.sh --update                 # refresh files; restart if running
sudo kiosk-monitor.sh --remove [--purge]       # remove binaries; --purge also drops /etc/kiosk-monitor
sudo kiosk-monitor.sh --reconfig               # re-write kiosk-monitor.conf with every supported option
kiosk-monitor.sh --status                      # show instance config + service status
kiosk-monitor.sh --version
```

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

Run `wlr-randr` as the desktop user to list available output names.

### Mode-specific
Chromium (`MODE=chrome`):
- `CHROMIUM_BIN` — path override (`/usr/bin/chromium` by default on trixie).
- `BIRDSEYE_AUTO_FILL` — `true` injects CSS to force the Frigate Birdseye grid to fill the viewport.
- `BIRDSEYE_MATCH_PATTERN` — override the extension match pattern (defaults to `scheme://host/*` from `URL`).
- `BIRDSEYE_EXTENSION_DIR` — custom extension dir (default: under the profile).
- `DEVTOOLS_AUTO_OPEN`, `DEVTOOLS_REMOTE_PORT` — debugging helpers.

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
- Logs go to stdout and `/dev/shm/kiosk.log` (override via `LOG=...`). Follow them live with `journalctl -u kiosk-monitor -f`.
- Each Chromium instance runs with its own `--user-data-dir`, isolating cookies/session state.
- VLC runs with `--intf=dummy` (no UI), `--fullscreen`, and a unique `--logfile` as a process fingerprint.
- Window placement is computed from `wlr-randr --json`: each instance launches at its output's top-left with that output's native resolution, and labwc fullscreens it to the containing monitor.
- Freeze detection uses `grim -o <OUTPUT>` so each instance is compared only against its own monitor.

## Manual run / debugging
```bash
sudo LOG=/tmp/kiosk.log DEBUG=true /usr/local/bin/kiosk-monitor.sh --debug
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
