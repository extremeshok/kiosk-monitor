#!/usr/bin/env bash
# Record the kiosk-monitor TUI as an asciinema .cast file.
#
# Usage (on the target Pi, as root):
#     sudo apt install asciinema expect
#     sudo ./record-tui.sh           # writes /tmp/kiosk-monitor-tui.cast
#
# Convert the .cast to GIF locally (needs `agg`):
#     agg --cols 100 --rows 30 --speed 1.2 kiosk-monitor-tui.cast tui.gif
#
# Extract PNG stills from the GIF (needs `ffmpeg`):
#     ffmpeg -y -i tui.gif -vf "select='eq(n,60)'" -vframes 1 main-menu.png
set -Eeuo pipefail

cast=${1:-/tmp/kiosk-monitor-tui.cast}
cols=${COLS:-100}
rows=${ROWS:-30}

command -v asciinema >/dev/null || { echo "install asciinema: sudo apt install asciinema"; exit 1; }
command -v expect    >/dev/null || { echo "install expect: sudo apt install expect";    exit 1; }
command -v kiosk-monitor >/dev/null || { echo "kiosk-monitor must be installed first"; exit 1; }

# Build a tiny expect driver that walks the menus.
drv=$(mktemp --suffix=.exp)
cat >"$drv" <<'EOF'
set timeout 20
set env(TERM)    "xterm-256color"
log_user 1
spawn -noecho kiosk-monitor
# 1. Main menu appears — hold on it for a beat so viewers can read it.
expect -re "Instance 1:"
sleep 3
# 2. Move cursor down to "service" (6 downs from instance1).
for {set i 0} {$i < 5} {incr i} { send -- "\033\[B"; sleep 0.12 }
sleep 1.2
# 3. Enter the service submenu.
send -- "\r"
expect -re "install"
sleep 2.5
# 4. Back to main menu.
send -- "\033"
expect -re "Main menu"
sleep 1.2
# 5. Move to "instance1" and open it.
for {set i 0} {$i < 7} {incr i} { send -- "\033\[A"; sleep 0.08 }
send -- "\r"
expect -re "Edit instance"
sleep 2.5
send -- "\033"
expect -re "Main menu"
sleep 0.8
# 6. Quit with ESC.
send -- "\033"
expect eof
EOF
trap 'rm -f "$drv"' EXIT

stty cols "$cols" rows "$rows" 2>/dev/null || true
ASCIINEMA_REC=1 asciinema rec -q --overwrite -c "expect -f $drv" "$cast"
printf '\nRecording saved to %s\n' "$cast"
