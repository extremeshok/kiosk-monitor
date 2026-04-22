# kiosk-monitor media guide

Visual documentation for the interactive configuration TUI.
This file is the asset inventory plus the refresh checklist.

## Current assets

1. `docs/media/main-menu.png`
   Top-level configuration menu. Shows both instances, the Frigate
   helper summary, timing, service state, and the save/apply actions.

2. `docs/media/service-menu.png`
   The **Service** submenu — install / enable at boot / start / stop /
   restart / view logs — all from inside the TUI. No CLI needed after
   first launch.

3. `docs/media/instance-edit.png`
   The **Instance 1** editor. Same screen is reused for instance 2.

4. `docs/media/frigate-menu.png`
   The **Frigate helper** submenu — dark mode, theme, Birdseye
   auto-fill width/height, margin.

5. `docs/media/kiosk-monitor-demo.gif`
   Short animation that cycles through main menu → service submenu →
   instance editor → Frigate helper. Used as the hero animation in the
   README.

6. `docs/media/record-tui.sh`
   Helper script for re-recording the asciinema flow. Not required for
   PNG refresh (see below), kept for future cast-based captures.

## README placement

- Hero section: `docs/media/kiosk-monitor-demo.gif`
- Quick-tour section: `main-menu.png`, `service-menu.png`
- Configuration detail: `instance-edit.png`, `frigate-menu.png`

## Refresh guidance

Capture screenshots on the target Raspberry Pi itself — the rendering
is authentic labwc + lxterminal + whiptail.

### Prereqs (one-off, on the Pi)

```bash
sudo apt install wtype grim lxterminal whiptail
```

### Step-by-step capture procedure

1. **Stop the kiosk so the desktop is visible:**
   ```bash
   sudo systemctl stop kiosk-monitor
   ```

2. **Write a readable lxterminal profile** (16pt Monospace, no chrome):
   ```bash
   mkdir -p ~/.config/lxterminal
   cat > ~/.config/lxterminal/lxterminal.conf <<'CFG'
   [general]
   fontname=Monospace 16
   hidescrollbar=true
   hidemenubar=true
   geometry_columns=110
   geometry_rows=32
   CFG
   ```

3. **Prime sudo (TUI requires root):**
   ```bash
   sudo -v
   ```

4. **Launch the TUI on the Pi desktop** (HDMI-A-1 by default):
   ```bash
   export XDG_RUNTIME_DIR=/run/user/$(id -u)
   export WAYLAND_DISPLAY=wayland-0
   lxterminal --geometry=110x32 --command='sudo kiosk-monitor' &
   sleep 4
   ```

5. **Capture each state** with `grim` and `wtype` for navigation:
   ```bash
   shots=/tmp/tui-shots && mkdir -p "$shots"
   grim -o HDMI-A-1 "$shots/main-menu.png"

   # Navigate to "service" (5 Downs) and snap the submenu.
   for _ in 1 2 3 4 5; do wtype -k Down; sleep 0.1; done
   wtype -k Return; sleep 1
   grim -o HDMI-A-1 "$shots/service-menu.png"

   wtype -k Escape; sleep 0.8
   # Navigate to "instance1" (5 Ups) and snap the instance editor.
   for _ in 1 2 3 4 5; do wtype -k Up; sleep 0.05; done
   wtype -k Return; sleep 1
   grim -o HDMI-A-1 "$shots/instance-edit.png"

   wtype -k Escape; sleep 0.5
   # Navigate to "frigate" (2 Downs) and snap the Frigate menu.
   for _ in 1 2; do wtype -k Down; sleep 0.1; done
   wtype -k Return; sleep 1
   grim -o HDMI-A-1 "$shots/frigate-menu.png"
   ```

6. **Restart the kiosk:**
   ```bash
   pkill lxterminal
   sudo systemctl start kiosk-monitor
   ```

7. **Crop each PNG** to the terminal region (removes desktop wallpaper):
   ```bash
   # Locally on your workstation, after scp'ing the PNGs:
   for f in main-menu service-menu instance-edit frigate-menu; do
     ffmpeg -y -i $f.png -vf "crop=1620:800:150:160" docs/media/$f.png
   done
   ```

8. **Rebuild the GIF** from the cropped PNGs:
   ```bash
   rm -rf /tmp/gif-frames && mkdir /tmp/gif-frames
   frame=0
   for src in main-menu service-menu main-menu instance-edit main-menu frigate-menu; do
     for _ in $(seq 1 25); do
       cp "docs/media/$src.png" "/tmp/gif-frames/f$(printf '%05d' $frame).png"
       frame=$((frame+1))
     done
   done
   ffmpeg -y -framerate 12 -i /tmp/gif-frames/f%05d.png \
     -vf "scale=900:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=96[p];[b][p]paletteuse=dither=bayer" \
     docs/media/kiosk-monitor-demo.gif
   ```

## Refresh rules

- Capture real screens from the current TUI — never mock or redraw.
- Keep the lxterminal font at 16pt and geometry at 110x32 so every
  screenshot has the same proportions.
- Do not include personal hostnames, IPs, or camera credentials in the
  captured URLs. The demo rig uses the Frigate Birdseye URL/stream
  from the sample config; edit `/etc/kiosk-monitor/kiosk-monitor.conf`
  to placeholders before capturing if you're documenting from a live
  deployment.
- Re-run the crop + GIF build so every asset is regenerated consistently.
