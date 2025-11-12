# kiosk-monitor

Browser watchdog for kiosk-style displays. The service keeps a single kiosk window pinned to your dashboard, restarts the browser when the page or GPU freezes, and scrubs the profile so crash prompts and duplicate tabs never appear after a reboot.

## Features
- Launches Chromium or Firefox in kiosk mode against a configurable URL (default Birdseye view)
- Optional Firefox profile tuning for hardware-accelerated H.264/MJPEG streams
- Monitors reachability of the target URL and captures screen hashes to detect frozen frames
- Auto-recovers from network outages, browser crashes, or repeated stalls with storm-protection backoff
- Self-install, update, and removal via `--install`, `--update`, `--remove`
- Maintains dedicated browser profiles to suppress "restore previous session" prompts and duplicate tabs
- Enforces a single kiosk browser instance by pruning stray processes
- Pre-warms browser binaries/profile caches to shorten cold-start times on slow media

## Requirements
- Debian/Raspberry Pi OS or other systemd-based distro with a graphical session on `seat0`
- Packages: `chromium-browser`, `curl`, `sudo`, `x11-apps`, `grim` (Wayland), `wayland-utils`, `fbset`, `coreutils`, `procps` (provides `ps`/`pgrep`)
- Chromium binary at `/usr/bin/chromium-browser` when `BROWSER=chromium` (override with `CHROMIUM_BIN`)
- Optional: `firefox`/`firefox-esr` plus `libopenh264-2` (or equivalent) when `BROWSER=firefox`

## Quick Install
```bash
curl -fsSL https://raw.githubusercontent.com/extremeshok/kiosk-monitor/main/kiosk-monitor.sh \
  | sudo bash -s -- --install --url "http://192.168.3.222:30059/?Birdseye" --gui-user spaceman
```

To deploy Firefox instead of Chromium, prefix the installer with `BROWSER=firefox` (ensure Firefox and the H.264 codec are installed):
```bash
BROWSER=firefox sudo kiosk-monitor.sh --install --url "https://example.local" --gui-user spaceman
```

The installer will download `kiosk-monitor.sh` and `kiosk-monitor.service`, place them in `/usr/local/bin` and `/etc/systemd/system`, create `/etc/kiosk-monitor/kiosk-monitor.conf` (alongside a `.sample`), run `systemctl daemon-reload`, and enable/start the service. Use `--no-start` if you want to enable without starting immediately.

### Update or Remove
```bash
# Update binaries (restarts the service if running)
sudo kiosk-monitor.sh --update

# Remove files; add --purge to delete /etc/kiosk-monitor
sudo kiosk-monitor.sh --remove [--purge]

# Switch browsers during an update
sudo kiosk-monitor.sh --update --browser firefox

# Refresh / regenerate the config (writes current values plus new defaults)
sudo kiosk-monitor.sh --reconfig
```

To stage a custom branch or mirror, set `BASE_URL` before invoking any management command:
```bash
BASE_URL="https://raw.githubusercontent.com/<fork>/kiosk-monitor/feature-branch" sudo kiosk-monitor.sh --install
```

## Configuration (`/etc/kiosk-monitor/kiosk-monitor.conf`)
The installer seeds an override file. Edit it to customise runtime behaviour.

| Variable      | Description                                                                 | Default |
| ------------- | --------------------------------------------------------------------------- | ------- |
| `URL`         | Page to load in browser kiosk mode                                           | Birdseye URL |
| `GUI_USER`    | Desktop user that owns the display session; autodetected when empty          | *(auto)* |
| `BROWSER`     | `chromium` (default) or `firefox`                                            | `chromium` |
| `CHROMIUM_BIN`| Override path to Chromium binary                                             | `/usr/bin/chromium-browser` |
| `FIREFOX_BIN` | Override path to Firefox binary                                              | `/usr/bin/firefox` |
| `DEBUG`       | Set to `true` for verbose logging                                            | `false` |
| `PROFILE_ROOT`| Directory for the dedicated kiosk browser profile                            | `/home/<GUI_USER>/.local/share/kiosk-monitor` |
| `LOCK_FILE`   | Path for the single-instance flock lock (non-root users automatically fall back to `$XDG_RUNTIME_DIR/kiosk-monitor.lock` or `/tmp`) | `/var/lock/kiosk-monitor.lock` |
| `WAIT_FOR_URL`| `true` blocks Chromium until the dashboard responds; set `false` to start immediately | `true` |
| `CHROME_LAUNCH_DELAY` | Seconds to pause after spawning Chromium before checking PIDs        | `3` |
| `CHROME_READY_DELAY`  | Seconds to pause before detecting the main browser PID               | `2` |
| `PROFILE_TMPFS` | `true` stages the browser profile in RAM (tmpfs) for faster cold starts | `false` |
| `PROFILE_TMPFS_PATH` | Path to the tmpfs profile directory                                  | `/dev/shm/kiosk-monitor` |
| `PROFILE_SYNC_BACK` | `true` rsyncs the tmpfs profile back to disk on shutdown              | `false` |
| `PROFILE_TMPFS_PURGE` | `true` wipes the tmpfs directory after syncing back                   | `false` |
| `PROFILE_ARCHIVE` | Optional tar archive extracted into the profile before launch          | *(unset)* |
| `PROFILE_SYNC_INTERVAL` | Seconds between background syncs back to disk (0 disables)            | `0` |
| `PREWARM_ENABLED` | `true` pre-reads browser binaries/profile into page cache before launch | `true` |
| `PREWARM_PATHS` | Optional colon-separated extra paths to prewarm                             | *(unset)* |
| `PREWARM_MAX_FILES` | Max files touched per path during prewarm                                   | `512` |
| `PREWARM_SLICE_SIZE` | Bytes read from each file while prewarming                               | `262144` |
| `SESSION_READY_DELAY` | Seconds to delay the very first launch after boot                        | `0` |
| `SESSION_READY_CMD` | Optional command to wait for (runs until exit 0)                          | *(unset)* |
| `SESSION_READY_TIMEOUT` | Max seconds to wait for `SESSION_READY_CMD` (0 = wait forever)         | `0` |
| `GUI_SESSION_WAIT_TIMEOUT` | Seconds to wait for the GUI user’s login session before launching (0 disables) | `120` |
| `WAIT_FOR_URL_TIMEOUT` | Seconds to wait for the initial health probe before continuing anyway (0 = wait forever) | `0` |
| `SCREEN_SAMPLE_BYTES` | Bytes hashed from each screenshot during freeze detection                | `524288` |
| `SCREEN_SAMPLE_MODE` | `sample` hashes only the first `SCREEN_SAMPLE_BYTES`; `full` hashes the entire frame | `sample` |
| `SCREEN_DELAY` | Seconds the browser must run before screen-freeze hashing starts             | `120` |
| `LOG`         | Optional override for the runtime log (default `/dev/shm/kiosk.log`)         | *(unset)* |
| `HEALTH_INTERVAL` | Seconds between health-check cycles                                      | `30` |
| `HEALTH_CONNECT_TIMEOUT` | Curl connect-timeout per health probe (seconds)                    | `2` |
| `HEALTH_TOTAL_TIMEOUT` | Curl max-time per health probe (seconds)                             | `6` |
| `STALL_RETRIES` | Screen-hash misses tolerated before forcing a restart                    | `3` |
| `HEALTH_RETRIES` | Consecutive failed health probes before restarting the browser             | `6` |
| `RESTART_WINDOW` | Seconds considered when throttling excessive restarts                      | `600` |
| `MAX_RESTARTS` | Maximum restarts allowed within `RESTART_WINDOW` before backoff            | `10` |
| `CLEAN_RESET` | Seconds of healthy run required to reset the restart history                | `600` |
| `DEVTOOLS_AUTO_OPEN` | `true` auto-opens Chromium DevTools for each tab (useful for debugging) | `false` |
| `DEVTOOLS_REMOTE_PORT` | Port that Chromium’s remote debugger binds to (blank disables)        | *(unset)* |
| `BIRDSEYE_AUTO_FILL` | `true` injects CSS to force Frigate Birdseye to fill the viewport (Chromium only) | `true` |
| `BIRDSEYE_MATCH_PATTERN` | Override the Chrome extension match pattern (defaults to `scheme://host/*` from `URL`) | *(derived)* |
| `BIRDSEYE_EXTENSION_DIR` | Optional override for where the helper extension is written (defaults to `<PROFILE_ROOT>/birdseye-autofill`, then `/usr/local/share/kiosk-monitor/birdseye-autofill` if needed) | *(auto)* |

Apply changes with `sudo systemctl restart kiosk-monitor`.

The installer also writes `/etc/kiosk-monitor/kiosk-monitor.conf.sample`; copy or diff against it when introducing new options.
All management commands accept `--config /path/to/config.conf` if you need to operate on an alternate configuration file.
By default the watchdog waits up to `GUI_SESSION_WAIT_TIMEOUT` seconds for the GUI user’s `loginctl` session to appear before launching, and it hashes `SCREEN_SAMPLE_BYTES` from each screenshot (`SCREEN_SAMPLE_MODE=sample`) when checking for stuck frames. Increase the bytes or switch to `SCREEN_SAMPLE_MODE=full` if you have high-resolution dashboards that continue to animate outside the sampled region.

## Runtime Behaviour
- Logs are mirrored to stdout and `/dev/shm/kiosk.log` (override via `LOG`)
- Additional troubleshooting: `journalctl -u kiosk-monitor -f`
- The watchdog sanitises the active browser profile before every launch, clearing session snapshots and ensuring only one kiosk tab is opened

## Manual Run / Debugging
You can execute the watchdog manually (from the project root) to trial changes:
```bash
sudo LOG=/tmp/kiosk.log DEBUG=true bash kiosk-monitor.sh --debug
```
Press `Ctrl+C` to stop; the systemd unit will relaunch it when enabled.

## Service Reference
`/etc/systemd/system/kiosk-monitor.service`:
```ini
[Unit]
Description=Kiosk Monitor Watchdog
Documentation=https://github.com/extremeshok/kiosk-monitor
After=network-online.target graphical.target
Wants=network-online.target

[Service]
Type=simple
User=spaceman
Environment=GUI_USER=spaceman
Environment=BROWSER=chromium
Environment=DISPLAY=:2
Environment=XDG_RUNTIME_DIR=/run/user/1000
EnvironmentFile=-/etc/kiosk-monitor/kiosk-monitor.conf
ExecStart=/usr/local/bin/kiosk-monitor.sh
ExecStop=/bin/kill -s TERM $MAINPID
Restart=always
RestartSec=5
SyslogIdentifier=kiosk-monitor
SuccessExitStatus=0 130 143

[Install]
WantedBy=multi-user.target
WantedBy=graphical.target
```

Reload systemd after any manual edits: `sudo systemctl daemon-reload`.

`ExecStop` sends the main watchdog process a `TERM`, and `SuccessExitStatus` tells systemd those signal-driven exits are expected (preventing unwanted restarts after `systemctl stop`).

The unit is tied to both `multi-user.target` and `graphical.target`, so it comes up automatically whether the system boots into a text console or a graphical desktop (no extra symlink juggling on different Pi images).

Adjust the `User` and `Environment` lines to match the user that owns your kiosk session (for example, `pi`).

When `PROFILE_TMPFS=true`, the value of `PROFILE_ROOT` is treated as the persistent on-disk copy that seeds the tmpfs runtime directory.

Set `BROWSER=firefox` in `/etc/kiosk-monitor/kiosk-monitor.conf` (or export it before running the installer) to switch the kiosk engine.

### Faster Launch Tips (Pi-class hardware)
- **Run the profile from RAM:** set `PROFILE_TMPFS=true` and optionally `PROFILE_SYNC_BACK=true` to rsync changes back to disk on exit. The default tmpfs path is `/dev/shm/kiosk-monitor`; customise with `PROFILE_TMPFS_PATH` if needed.
- **Keep the seed warm:** combine `PROFILE_SYNC_BACK=true` with `PROFILE_SYNC_INTERVAL=900` (for example) so the tmpfs profile is mirrored back to persistent storage every 15 minutes.
- **Seed from a tarball:** build a tuned profile once (for Chromium: `tar -cf /var/lib/kiosk-monitor/profile.tar .config/chromium/Default`; for Firefox, archive your dedicated profile directory) and point `PROFILE_ARCHIVE` to it. Extraction into tmpfs is much quicker than replaying thousands of tiny file operations.
- **Pre-warm on boot:** leave `PREWARM_ENABLED=true` (and optionally extend `PREWARM_PATHS`) so the watchdog touches the browser binary/profile before launch, reducing SD-card cold start times.
- **Defer the first launch:** set `SESSION_READY_DELAY=15` (and/or a `SESSION_READY_CMD`) to give the desktop stack a chance to finish initialising before the kiosk browser starts.
- **Skip the initial URL wait:** if the dashboard is occasionally slow, set `WAIT_FOR_URL=false` so Chromium begins loading immediately while the watchdog continues health checks in the background.
- **Trim the delays:** reduce `CHROME_LAUNCH_DELAY` / `CHROME_READY_DELAY` after observing a few boots; the defaults favour stability on slower SD cards.

### Frigate Birdseye Auto-Fill
If the Frigate Birdseye UI keeps the `.react-resizable` grid squashed until you drag the handle, set `BIRDSEYE_AUTO_FILL=true` in `/etc/kiosk-monitor/kiosk-monitor.conf`.
When enabled (Chromium only), kiosk-monitor installs a minimal Chrome extension inside the kiosk profile (`<PROFILE_ROOT>/birdseye-autofill` by default, falling back to `/usr/local/share/kiosk-monitor/birdseye-autofill` if necessary, or a custom `BIRDSEYE_EXTENSION_DIR` when supplied) that injects CSS to force the grid to occupy the full viewport and hides the resize handle.
You can adjust which pages receive the CSS by setting `BIRDSEYE_MATCH_PATTERN` (falls back to `scheme://host/*` based on your `URL`).

The default stylesheet also hard-codes the Birdseye grid and canvas heights to `1000px` while capping the width at `1800px` so the Pi display renders predictably. Tweak those values (or remove them entirely) by editing `<PROFILE_ROOT>/birdseye-autofill/fullscreen.css` and re-running `kiosk-monitor.sh --update` if you need a different layout.


### Example of freeze detection

```
Nov 12 01:34:05 pi4 kiosk-monitor[17214]: Waiting for http://192.168.3.222:30059/?Birdseye …
Nov 12 01:34:05 pi4 kiosk-monitor[17214]: Target http://192.168.3.222:30059/?Birdseye is reachable at Wed Nov 12 01:34:05 AM 2025 — continuing.
Nov 12 01:34:55 pi4 kiosk-monitor[17214]: Chromium main PID is 17258 (launcher 17256)
Nov 12 01:44:31 pi4 kiosk-monitor[17214]: Screen unchanged for 1/3 cycles at Wed Nov 12 01:44:31 AM 2025
Nov 12 01:45:01 pi4 kiosk-monitor[17214]: Screen unchanged for 2/3 cycles at Wed Nov 12 01:45:01 AM 2025
Nov 12 01:45:32 pi4 kiosk-monitor[17214]: Screen unchanged for 3/3 cycles at Wed Nov 12 01:45:32 AM 2025
Nov 12 01:45:32 pi4 kiosk-monitor[17214]: Screen appears frozen — restarting Chromium...
Nov 12 01:45:32 pi4 kiosk-monitor[17214]: Stopping Chromium PID 17258…
Nov 12 01:46:22 pi4 kiosk-monitor[17214]: Chromium main PID is 17793 (launcher 17791)
```
