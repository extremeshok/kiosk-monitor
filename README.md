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
| `LOCK_FILE`   | Path for the single-instance flock lock                                      | `/var/lock/kiosk-monitor.lock` |
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
| `LOG`         | Optional override for the runtime log (default `/dev/shm/kiosk.log`)         | *(unset)* |

Apply changes with `sudo systemctl restart kiosk-monitor`.

The installer also writes `/etc/kiosk-monitor/kiosk-monitor.conf.sample`; copy or diff against it when introducing new options.

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
```

Reload systemd after any manual edits: `sudo systemctl daemon-reload`.

`ExecStop` sends the main watchdog process a `TERM`, and `SuccessExitStatus` tells systemd those signal-driven exits are expected (preventing unwanted restarts after `systemctl stop`).

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
