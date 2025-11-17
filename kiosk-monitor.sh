#!/usr/bin/env bash
# ======================================================================
# Coded by Adrian Jon Kriel :: admin@extremeshok.com
# ======================================================================
# kiosk-monitor.sh :: version 5.4.0
#======================================================================
# Monitors a Chromium kiosk session on Raspberry Pi:
#  - Launches the browser in fullscreen (kiosk‑style) to a specified URL
#  - Patches browser preferences on every start to suppress crash/restore prompts
#  - Health‑checks the target URL *and* compares screen hashes to detect visual freezes
#  - Automatically restarts the browser after network failure, crashes, or frozen display
#  - Storm‑protection: aborts after too many restarts within a rolling window
#  - Writes verbose logs when DEBUG=true or --debug is passed
#
#======================================================================
# Requirements:
#   - Debian/Raspberry Pi OS (systemd‑based) with:
#       bash, curl, x11-apps, grim, wayland-utils, fbset, coreutils (cksum/base64)
#   - A graphical session running on seat0 (user is auto‑detected via loginctl)
#   - Chromium/Chrome installed as /usr/bin/chromium-browser (or set CHROMIUM_BIN)
#======================================================================
# DEBUGGING:
#   • Enable verbose output by either:
#       export DEBUG=true          # environment variable
#       ./kiosk-watchdog.sh --debug
#======================================================================
# Usage:
#   ./kiosk-monitor.sh --install
#   ./kiosk-monitor.sh --help
#   ./kiosk-monitor.sh --reconfig
#======================================================================
# Configuration:
#   Override behaviour via /etc/kiosk-monitor/kiosk-monitor.conf (shell-style) or environment vars.
#   --reconfig will update/create a new configuration file
# ======================================================================

# requires:
#   apt install x11-apps grim fbset wayland-utils

set -Eeuo pipefail
GRIM_OUT_OPT=()

CONFIG_FILE_OVERRIDE=""
CONFIG_ARGV=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config=*)
      CONFIG_FILE_OVERRIDE="${1#--config=}"
      shift
      continue
      ;;
    --config)
      shift
      if [ "$#" -eq 0 ]; then
        echo "Error: --config requires a path" >&2
        exit 1
      fi
      CONFIG_FILE_OVERRIDE="$1"
      shift
      continue
      ;;
    --)
      CONFIG_ARGV+=("$1")
      shift
      while [ "$#" -gt 0 ]; do
        CONFIG_ARGV+=("$1")
        shift
      done
      break
      ;;
    *)
      CONFIG_ARGV+=("$1")
      shift
      ;;
  esac
done

if [ "${#CONFIG_ARGV[@]}" -gt 0 ]; then
  set -- "${CONFIG_ARGV[@]}"
else
  set --
fi

SCRIPT_VERSION="5.4.0"

CONFIG_DIR_DEFAULT="/etc/kiosk-monitor"
CONFIG_DIR_ENV="${CONFIG_DIR:-}"
CONFIG_FILE_ENV="${CONFIG_FILE:-}"

if [ -n "$CONFIG_FILE_OVERRIDE" ]; then
  CONFIG_FILE="$CONFIG_FILE_OVERRIDE"
  CONFIG_DIR=$(dirname "$CONFIG_FILE")
elif [ -n "$CONFIG_FILE_ENV" ]; then
  CONFIG_FILE="$CONFIG_FILE_ENV"
  if [ -n "$CONFIG_DIR_ENV" ]; then
    CONFIG_DIR="$CONFIG_DIR_ENV"
  else
    CONFIG_DIR=$(dirname "$CONFIG_FILE")
  fi
else
  CONFIG_DIR="${CONFIG_DIR_ENV:-$CONFIG_DIR_DEFAULT}"
  CONFIG_FILE="$CONFIG_DIR/kiosk-monitor.conf"
fi

ENV_FILE="${ENV_FILE:-$CONFIG_FILE}"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

DEFAULT_URL="http://192.168.3.222:30059/?Birdseye"
DEFAULT_BASE_URL="https://raw.githubusercontent.com/extremeshok/kiosk-monitor/main"
BASE_URL="${BASE_URL:-$DEFAULT_BASE_URL}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
SERVICE_PATH="${SERVICE_PATH:-/etc/systemd/system/kiosk-monitor.service}"
LOCK_FILE="${LOCK_FILE:-/var/lock/kiosk-monitor.lock}"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
WAIT_FOR_URL="${WAIT_FOR_URL:-true}"
if [ -n "${CHROME_LAUNCH_DELAY:-}" ] && [ -z "${CHROME_LAUNCH_DELAY_SECONDS:-}" ]; then
  CHROME_LAUNCH_DELAY_SECONDS="$CHROME_LAUNCH_DELAY"
fi
if [ -n "${CHROME_READY_DELAY:-}" ] && [ -z "${CHROME_READY_DELAY_SECONDS:-}" ]; then
  CHROME_READY_DELAY_SECONDS="$CHROME_READY_DELAY"
fi
CHROME_LAUNCH_DELAY_SECONDS="${CHROME_LAUNCH_DELAY_SECONDS:-30}"
CHROME_READY_DELAY_SECONDS="${CHROME_READY_DELAY_SECONDS:-20}"
PROFILE_TMPFS="${PROFILE_TMPFS:-false}"
PROFILE_TMPFS_PATH="${PROFILE_TMPFS_PATH:-/dev/shm/kiosk-monitor}"
PROFILE_SYNC_BACK="${PROFILE_SYNC_BACK:-false}"
PROFILE_ARCHIVE="${PROFILE_ARCHIVE:-}"
PROFILE_TMPFS_PURGE="${PROFILE_TMPFS_PURGE:-false}"
PROFILE_SYNC_INTERVAL="${PROFILE_SYNC_INTERVAL:-0}"
SESSION_READY_DELAY="${SESSION_READY_DELAY:-0}"
SESSION_READY_CMD="${SESSION_READY_CMD:-}"
SESSION_READY_TIMEOUT="${SESSION_READY_TIMEOUT:-0}"
BROWSER="${BROWSER:-chromium}"
BROWSER=$(printf '%s' "$BROWSER" | tr '[:upper:]' '[:lower:]')
BIRDSEYE_AUTO_FILL="${BIRDSEYE_AUTO_FILL:-true}"
BIRDSEYE_MATCH_PATTERN="${BIRDSEYE_MATCH_PATTERN:-}"
BIRDSEYE_EXTENSION_DIR="${BIRDSEYE_EXTENSION_DIR:-}"
GUI_SESSION_WAIT_TIMEOUT="${GUI_SESSION_WAIT_TIMEOUT:-120}"
SCREEN_SAMPLE_BYTES="${SCREEN_SAMPLE_BYTES:-524288}"
SCREEN_SAMPLE_MODE="${SCREEN_SAMPLE_MODE:-sample}"
BIRDSEYE_EXTENSION_PATH=""
SCREEN_DELAY=${SCREEN_DELAY:-120}
HEALTH_INTERVAL=${HEALTH_INTERVAL:-30}
HEALTH_CONNECT_TIMEOUT=${HEALTH_CONNECT_TIMEOUT:-3}
HEALTH_TOTAL_TIMEOUT=${HEALTH_TOTAL_TIMEOUT:-8}
WAIT_FOR_URL_TIMEOUT=${WAIT_FOR_URL_TIMEOUT:-0}
MIN_UPTIME_BEFORE_START=${MIN_UPTIME_BEFORE_START:-60}
STALL_RETRIES=${STALL_RETRIES:-3}
HEALTH_RETRIES=${HEALTH_RETRIES:-6}
RESTART_WINDOW=${RESTART_WINDOW:-600}
MAX_RESTARTS=${MAX_RESTARTS:-10}
CLEAN_RESET=${CLEAN_RESET:-600}
DEVTOOLS_AUTO_OPEN="${DEVTOOLS_AUTO_OPEN:-false}"
DEVTOOLS_REMOTE_PORT="${DEVTOOLS_REMOTE_PORT:-}"
PROFILE_SYNC_PID=""

if ! [[ "$SCREEN_SAMPLE_BYTES" =~ ^[0-9]+$ ]] || [ "$SCREEN_SAMPLE_BYTES" -le 0 ]; then
  SCREEN_SAMPLE_BYTES=524288
fi
case "$SCREEN_SAMPLE_MODE" in
  full|sample) ;;
  *) SCREEN_SAMPLE_MODE="sample" ;;
esac

DEFERRED_LAUNCH_DONE=false
SHUTDOWN_REQUESTED=false

case "$BROWSER" in
  chromium|chrome)
    BROWSER_FLAVOR="chromium"
    BROWSER_LABEL="Chromium"
    if [ -n "${CHROMIUM_BIN:-}" ]; then
      CHROME="$CHROMIUM_BIN"
    elif command -v chromium-browser >/dev/null 2>&1; then
      CHROME="$(command -v chromium-browser)"
    elif command -v chromium >/dev/null 2>&1; then
      CHROME="$(command -v chromium)"
    else
      CHROME="/usr/bin/chromium-browser"
    fi
    ;;
  *)
    echo "Unsupported BROWSER value: $BROWSER" >&2
    echo "Set BROWSER to 'chromium'." >&2
    exit 1
    ;;
esac

ACTION="run"
case "${1:-}" in
  --install|--remove|--update|--reconfig)
    ACTION="${1#--}"
    shift
    ;;
  --help|-h)
    ACTION="help"
    shift
    ;;
  --version)
    ACTION="version"
    shift
    ;;
esac
ACTION_ARGS=("$@")

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Error: required command %s not found in PATH\n' "$1" >&2
    exit 1
  fi
}

init_log_file() {
  local target=$1
  local dir
  dir=$(dirname "$target")
  if ! mkdir -p "$dir" 2>/dev/null; then
    return 1
  fi
  if ! ( : > "$target" ) 2>/dev/null; then
    rm -f "$target" 2>/dev/null || true
    if ! ( : > "$target" ) 2>/dev/null; then
      return 1
    fi
  fi
  return 0
}

derive_match_pattern() {
  local raw=$1
  local fallback="http://*/*"
  if [ -z "$raw" ]; then
    printf '%s\n' "$fallback"
    return
  fi
  if [[ "$raw" != *"://"* ]]; then
    raw="http://$raw"
  fi
  local scheme="${raw%%://*}"
  local remainder="${raw#*://}"
  if [ "$scheme" = "$raw" ]; then
    scheme="http"
    remainder="$raw"
  fi
  local netloc="${remainder%%/*}"
  if [ -z "$netloc" ]; then
    netloc="*"
  fi
  printf '%s://%s/*\n' "$scheme" "$netloc"
}

open_lock_file() {
  local requested=$1
  local uid="${EUID:-$(id -u)}"
  local -a candidates=()

  if [ -n "$requested" ]; then
    candidates+=( "$requested" )
  fi
  if [ "$uid" -ne 0 ]; then
    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
      candidates+=( "${XDG_RUNTIME_DIR%/}/kiosk-monitor.lock" )
    fi
    candidates+=( "/tmp/kiosk-monitor-${uid}.lock" )
  fi
  candidates+=( "/tmp/kiosk-monitor-${uid}.lock" )

  local target dir
  for target in "${candidates[@]}"; do
    [ -n "$target" ] || continue
    dir=$(dirname "$target")
    if ! mkdir -p "$dir" 2>/dev/null; then
      continue
    fi
    if { exec 200>"$target"; } 2>/dev/null; then
      if [ -n "$requested" ] && [ "$target" != "$requested" ]; then
        printf 'Warning: unable to use lock file %s; switched to %s\n' "$requested" "$target" >&2
      fi
      LOCK_FILE="$target"
      return 0
    fi
  done
  return 1
}

regex_escape() {
  # Escape characters with special meaning in POSIX basic regular expressions
  printf '%s' "$1" | sed -e 's/[][(){}.^$+*?|\\]/\\&/g'
}

clear_directory() {
  local dir=$1
  if [ -d "$dir" ]; then
    find "$dir" -mindepth 1 -exec rm -rf {} + 2>/dev/null || true
  else
    mkdir -p "$dir"
  fi
}

mirror_tree() {
  local src=$1 dst=$2
  if [ "$src" = "$dst" ]; then
    return 0
  fi
  [ -d "$src" ] || return 0
  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$src/" "$dst/" 2>/dev/null || true
  else
    clear_directory "$dst"
    cp -a "$src/." "$dst/" 2>/dev/null || true
  fi
}

extract_archive() {
  local archive=$1 dest=$2
  if [ ! -f "$archive" ]; then
    return 1
  fi
  need_cmd tar
  clear_directory "$dest"
  if ! tar -xaf "$archive" -C "$dest"; then
    echo "Failed to extract $archive" >&2
    return 1
  fi
  return 0
}

auto_detect_gui_user() {
  if [ -n "${GUI_USER:-}" ] && [ "$GUI_USER" != "root" ]; then
    return 0
  fi

  local candidate=""
  if command -v loginctl >/dev/null 2>&1; then
    while read -r session _ user seat _; do
      [ -n "$session" ] || continue
      [ -n "$user" ] || continue
      [ "$user" = "root" ] && continue

      local active type
      active=$(loginctl show-session "$session" -p Active --value 2>/dev/null | tr '[:upper:]' '[:lower:]') || active=""
      type=$(loginctl show-session "$session" -p Type --value 2>/dev/null | tr '[:upper:]' '[:lower:]') || type=""
      if [ "$active" = "yes" ] && { [ "$type" = "wayland" ] || [ "$type" = "x11" ] || [ -z "$type" ]; }; then
        if [ -z "$seat" ] || [ "$seat" = "seat0" ]; then
          candidate="$user"
          break
        fi
      fi
      if [ -z "$candidate" ]; then
        candidate="$user"
      fi
    done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
  fi

  if [ -z "$candidate" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    candidate="$SUDO_USER"
  fi
  if [ -z "$candidate" ] && [ -n "${USER:-}" ] && [ "$USER" != "root" ]; then
    candidate="$USER"
  fi

  if [ -z "$candidate" ] || [ "$candidate" = "root" ]; then
    echo "No GUI user detected; set GUI_USER explicitly." >&2
    return 1
  fi

  GUI_USER="$candidate"
  export GUI_USER
  return 0
}

auto_detect_display() {
  local target_user=${1:-${GUI_USER:-}}
  if [ -n "${DISPLAY:-}" ]; then
    return 0
  fi
  if [ -z "$target_user" ]; then
    return 1
  fi

  if command -v loginctl >/dev/null 2>&1; then
    while read -r session _ user _; do
      [ "$user" = "$target_user" ] || continue
      local display
      display=$(loginctl show-session "$session" -p Display --value 2>/dev/null | tr -d '\n') || display=""
      if [ -n "$display" ]; then
        DISPLAY="$display"
        export DISPLAY
        return 0
      fi
    done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
  fi

  if [ -z "${DISPLAY:-}" ]; then
    DISPLAY=":0"
    export DISPLAY
  fi
  return 0
}

write_service_unit() {
  local gui_user=$1
  local display=$2
  local runtime_dir=$3
  local wayland_display=${4:-}
  local target_path=${5:-$SERVICE_PATH}
  local dependency=${6:-}
  local after_targets="network-online.target graphical.target"
  if [ -n "$dependency" ]; then
    after_targets="$after_targets $dependency"
  fi

  local tmp
  tmp=$(mktemp)
  {
    cat <<EOF
[Unit]
Description=Kiosk Monitor Watchdog
Documentation=https://github.com/extremeshok/kiosk-monitor
After=$after_targets
Wants=network-online.target
EOF
    if [ -n "$dependency" ]; then
      printf 'Requires=%s\n' "$dependency"
    fi
    cat <<'EOF'
StartLimitIntervalSec=0
StartLimitBurst=0

[Service]
Type=simple
EOF
    cat <<EOF
User=$gui_user
Environment=GUI_USER=$gui_user
Environment=DISPLAY=$display
Environment=XDG_RUNTIME_DIR=$runtime_dir
EOF
    if [ -n "$wayland_display" ]; then
      printf 'Environment=WAYLAND_DISPLAY=%s\n' "$wayland_display"
    fi
    cat <<EOF
EnvironmentFile=-$CONFIG_FILE
ExecStart=$INSTALL_DIR/kiosk-monitor.sh
ExecStop=/bin/kill -s TERM \$MAINPID
Restart=always
RestartSec=5
SyslogIdentifier=kiosk-monitor
StandardOutput=journal
StandardError=journal
SuccessExitStatus=0 130 143

[Install]
WantedBy=multi-user.target
WantedBy=graphical.target
EOF
  } > "$tmp"
  install -m 0644 "$tmp" "$target_path"
  rm -f "$tmp"
}

tailscaled_dependency_unit() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi
  if systemctl is-enabled --quiet tailscaled.service >/dev/null 2>&1; then
    printf 'tailscaled.service\n'
    return 0
  fi
  return 1
}

trim_chromium_cache() {
  local base="$PROFILE_DIR"
  rm -rf \
    "$base/Cache" \
    "$base/Code Cache" \
    "$base/GPUCache" \
    "$base/GrShaderCache" \
    "$base/ShaderCache" \
    "$base/DawnCache" \
    "$base/Application Cache" 2>/dev/null || true
}

maybe_defer_launch() {
  if [ "$DEFERRED_LAUNCH_DONE" = "true" ]; then
    return
  fi
  local delay="$SESSION_READY_DELAY"
  if [[ "$delay" =~ ^[0-9]+$ ]] && [ "$delay" -gt 0 ]; then
    echo "Delaying browser launch for $delay seconds (session warm-up)"
    sleep "$delay"
  fi
  if [ -n "$SESSION_READY_CMD" ]; then
    echo "Waiting for SESSION_READY_CMD to succeed…"
    local waited=0
    local timeout="$SESSION_READY_TIMEOUT"
    while true; do
      if eval "$SESSION_READY_CMD"; then
        break
      fi
      sleep 1
      waited=$((waited + 1))
      if [[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -gt 0 ] && [ "$waited" -ge "$timeout" ]; then
        echo "SESSION_READY_CMD timed out after $waited seconds; continuing."
        break
      fi
    done
  fi
  DEFERRED_LAUNCH_DONE=true
}

usage() {
  cat <<'EOF'
kiosk-monitor.sh — Browser kiosk watchdog and installer

Usage:
  kiosk-monitor.sh [--debug]
  kiosk-monitor.sh --install [--url URL] [--gui-user USER] [--browser BROWSER] [--no-start] [--base-url URL]
  kiosk-monitor.sh --update [--base-url URL] [--browser BROWSER]
  kiosk-monitor.sh --remove [--purge]
  kiosk-monitor.sh --reconfig [--config PATH]
  kiosk-monitor.sh --help | --version

Environment overrides:
  BASE_URL      Source for updates (default: project GitHub raw)
  INSTALL_DIR   Destination for the script (default: /usr/local/bin)
  SERVICE_PATH  systemd unit path (default: /etc/systemd/system/kiosk-monitor.service)
  CONFIG_DIR    Directory for config files (default: /etc/kiosk-monitor)
  CONFIG_FILE   Main config file path (default: /etc/kiosk-monitor/kiosk-monitor.conf)
  LOCK_FILE     Flock lock location (default: /var/lock/kiosk-monitor.lock)
Command-line override:
  --config PATH Use an alternate config file for this invocation

Management commands must be run as root. For kiosk runtime behaviour, see README.
EOF
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    printf 'Error: %s requires root; re-run with sudo\n' "$SCRIPT_NAME" >&2
    exit 1
  fi
}

download_component() {
  local source=$1
  local destination=$2
  local mode=${3:-755}
  local tmp

  need_cmd curl
  need_cmd install

  tmp=$(mktemp)
  if ! curl -fsSL "${BASE_URL%/}/$source" -o "$tmp"; then
    printf 'Error: failed to download %s from %s\n' "$source" "$BASE_URL" >&2
    rm -f "$tmp"
    exit 1
  fi
  install -m "$mode" "$tmp" "$destination"
  rm -f "$tmp"
}

ensure_script_installed() {
  local source=$1
  local target=$2
  local dir
  dir=$(dirname "$target")
  mkdir -p "$dir"

  local source_real target_real=""
  source_real=$(readlink -f "$source" 2>/dev/null || printf '%s' "$source")
  target_real=$(readlink -f "$target" 2>/dev/null || printf '')

  if [ -n "$target_real" ] && [ "$source_real" = "$target_real" ]; then
    chmod 0755 "$target"
    return 0
  fi

  install -m 0755 "$source" "$target"
}

render_config_file() {
  local url_override=$1
  local gui_override=$2
  local target="$CONFIG_FILE"
  local tmp

  mkdir -p "$CONFIG_DIR"
  tmp=$(mktemp)
  {
    echo '# kiosk-monitor configuration'
    printf 'URL="%s"\n' "${url_override:-$DEFAULT_URL}"
    if [ -n "$gui_override" ]; then
      printf 'GUI_USER="%s"\n' "$gui_override"
    else
      echo '# GUI_USER=""   # uncomment to pin the desktop user'
    fi
    echo 'BROWSER="chromium"   # only Chromium/Chrome is supported'
    echo '# CHROMIUM_BIN="/usr/bin/chromium-browser"'
    echo '# DEBUG=false'
    echo '# PROFILE_ROOT=""   # override kiosk profile directory if needed'
    echo '# WAIT_FOR_URL=true   # set to false to skip initial connectivity wait'
    echo '# CHROME_LAUNCH_DELAY=3'
    echo '# CHROME_READY_DELAY=2'
    echo '# PROFILE_TMPFS=false      # stage the browser profile in RAM (tmpfs)'
    echo '# PROFILE_TMPFS_PATH=/dev/shm/kiosk-monitor'
    echo '# PROFILE_SYNC_BACK=false  # rsync runtime profile back to disk on exit'
    echo '# PROFILE_TMPFS_PURGE=false # remove tmpfs profile contents on exit'
    echo '# PROFILE_ARCHIVE=""       # optional tar archive used to seed runtime profile'
    echo '# PROFILE_SYNC_INTERVAL=0   # seconds between background syncs (0 disables)'
    echo '# PREWARM_ENABLED=true      # pre-read browser binaries/profile into cache'
    echo '# PREWARM_PATHS=""          # optional colon-separated extra paths to warm'
    echo '# PREWARM_MAX_FILES=512      # max files per path to touch during prewarm'
    echo '# PREWARM_SLICE_SIZE=262144  # bytes read from each file during prewarm'
    echo '# SESSION_READY_DELAY=0      # seconds to defer first launch after boot'
    echo '# SESSION_READY_CMD=""        # optional command to wait for (returns success)'
    echo '# SESSION_READY_TIMEOUT=0    # max seconds to wait for SESSION_READY_CMD (0=forever)'
    echo '# LOCK_FILE="/var/lock/kiosk-monitor.lock"'
    echo '# INSTALL_DIR="/usr/local/bin"'
    echo '# SERVICE_PATH="/etc/systemd/system/kiosk-monitor.service"'
    echo '# BASE_URL="https://raw.githubusercontent.com/extremeshok/kiosk-monitor/main"'
  } > "$tmp"
  install -m 0644 "$tmp" "$target"
  rm -f "$tmp"
}

escape_config_value() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

emit_config_line() {
  local key=$1
  local value=$2
  printf '%s="%s"\n' "$key" "$(escape_config_value "$value")"
}

write_effective_config_file() {
  local target=$1
  need_cmd install
  mkdir -p "$(dirname "$target")"
  local launch_delay="${CHROME_LAUNCH_DELAY_SECONDS:-30}"
  local ready_delay="${CHROME_READY_DELAY_SECONDS:-20}"
  local tmp
  tmp=$(mktemp)
  {
    cat <<'EOF'
# kiosk-monitor configuration
# This file was generated by `kiosk-monitor.sh --reconfig`.
# Edit values as needed and restart the kiosk-monitor service.
EOF
    emit_config_line URL "${URL:-$DEFAULT_URL}"
    emit_config_line GUI_USER "${GUI_USER:-}"
    emit_config_line BROWSER "${BROWSER:-chromium}"
    emit_config_line CHROMIUM_BIN "${CHROMIUM_BIN:-}"
    emit_config_line DEBUG "${DEBUG:-false}"
    emit_config_line PROFILE_ROOT "${PROFILE_ROOT:-}"
    emit_config_line WAIT_FOR_URL "${WAIT_FOR_URL:-true}"
    emit_config_line CHROME_LAUNCH_DELAY "$launch_delay"
    emit_config_line CHROME_READY_DELAY "$ready_delay"
    emit_config_line PROFILE_TMPFS "${PROFILE_TMPFS:-false}"
    emit_config_line PROFILE_TMPFS_PATH "${PROFILE_TMPFS_PATH:-/dev/shm/kiosk-monitor}"
    emit_config_line PROFILE_SYNC_BACK "${PROFILE_SYNC_BACK:-false}"
    emit_config_line PROFILE_TMPFS_PURGE "${PROFILE_TMPFS_PURGE:-false}"
    emit_config_line PROFILE_ARCHIVE "${PROFILE_ARCHIVE:-}"
    emit_config_line PROFILE_SYNC_INTERVAL "${PROFILE_SYNC_INTERVAL:-0}"
    emit_config_line PREWARM_ENABLED "${PREWARM_ENABLED:-true}"
    emit_config_line PREWARM_PATHS "${PREWARM_PATHS:-}"
    emit_config_line PREWARM_MAX_FILES "${PREWARM_MAX_FILES:-512}"
    emit_config_line PREWARM_SLICE_SIZE "${PREWARM_SLICE_SIZE:-262144}"
    emit_config_line SESSION_READY_DELAY "${SESSION_READY_DELAY:-0}"
    emit_config_line SESSION_READY_CMD "${SESSION_READY_CMD:-}"
    emit_config_line SESSION_READY_TIMEOUT "${SESSION_READY_TIMEOUT:-0}"
    emit_config_line GUI_SESSION_WAIT_TIMEOUT "${GUI_SESSION_WAIT_TIMEOUT:-120}"
    emit_config_line LOCK_FILE "${LOCK_FILE:-/var/lock/kiosk-monitor.lock}"
    emit_config_line INSTALL_DIR "${INSTALL_DIR:-/usr/local/bin}"
    emit_config_line SERVICE_PATH "${SERVICE_PATH:-/etc/systemd/system/kiosk-monitor.service}"
    emit_config_line BASE_URL "${BASE_URL:-$DEFAULT_BASE_URL}"
    emit_config_line BIRDSEYE_AUTO_FILL "${BIRDSEYE_AUTO_FILL:-true}"
    emit_config_line BIRDSEYE_MATCH_PATTERN "${BIRDSEYE_MATCH_PATTERN:-}"
    emit_config_line BIRDSEYE_EXTENSION_DIR "${BIRDSEYE_EXTENSION_DIR:-}"
    emit_config_line SCREEN_SAMPLE_BYTES "${SCREEN_SAMPLE_BYTES:-524288}"
    emit_config_line SCREEN_SAMPLE_MODE "${SCREEN_SAMPLE_MODE:-sample}"
  } > "$tmp"
  install -m 0644 "$tmp" "$target"
  rm -f "$tmp"
}

ensure_config_file() {
  local url_override=$1
  local gui_override=$2
  local browser_override=$3
  local target="$CONFIG_FILE"

  mkdir -p "$CONFIG_DIR"
  if [ -f "$target" ]; then
    if [ -n "$url_override" ]; then
      if grep -q '^URL=' "$target"; then
        sed -i "s|^URL=.*|URL=\"$url_override\"|" "$target"
      else
        printf 'URL="%s"\n' "$url_override" >> "$target"
      fi
    fi
    if [ -n "$gui_override" ]; then
      if grep -q '^GUI_USER=' "$target"; then
        sed -i "s|^GUI_USER=.*|GUI_USER=\"$gui_override\"|" "$target"
      else
        printf 'GUI_USER="%s"\n' "$gui_override" >> "$target"
      fi
    fi
    if [ -n "$browser_override" ]; then
      if grep -q '^BROWSER=' "$target"; then
        sed -i "s|^BROWSER=.*|BROWSER=\"$browser_override\"|" "$target"
      else
        printf 'BROWSER="%s"\n' "$browser_override" >> "$target"
      fi
    fi
  else
    render_config_file "$url_override" "$gui_override"
    if [ -n "$browser_override" ]; then
      if grep -q '^BROWSER=' "$target"; then
        sed -i "s|^BROWSER=.*|BROWSER=\"$browser_override\"|" "$target"
      else
        printf 'BROWSER="%s"\n' "$browser_override" >> "$target"
      fi
    fi
  fi
}

install_self() {
  require_root
  need_cmd systemctl
  need_cmd install

  local url_override=""
  local gui_override=""
  local browser_override=""
  local display_override=""
  local autostart="yes"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --url)
        shift
        url_override="${1:-}"
        [ -n "$url_override" ] || { echo 'Error: --url needs a value' >&2; exit 1; }
        ;;
      --gui-user|--user)
        shift
        gui_override="${1:-}"
        [ -n "$gui_override" ] || { echo 'Error: --gui-user needs a value' >&2; exit 1; }
        ;;
      --display)
        shift
        display_override="${1:-}"
        [ -n "$display_override" ] || { echo 'Error: --display needs a value' >&2; exit 1; }
        ;;
      --browser)
        shift
        browser_override="${1:-}"
        [ -n "$browser_override" ] || { echo 'Error: --browser needs a value' >&2; exit 1; }
        browser_override=$(printf '%s' "$browser_override" | tr '[:upper:]' '[:lower:]')
        ;;
      --no-start)
        autostart="no"
        ;;
      --base-url)
        shift
        BASE_URL="${1:-}"
        [ -n "$BASE_URL" ] || { echo 'Error: --base-url needs a value' >&2; exit 1; }
        ;;
      *)
        printf 'Error: unknown install option %s\n' "$1" >&2
        usage
        exit 1
        ;;
    esac
    shift
  done

  local effective_gui
  if [ -n "$gui_override" ]; then
    GUI_USER="$gui_override"
    effective_gui="$gui_override"
  else
    if ! auto_detect_gui_user; then
      echo 'Unable to determine GUI user automatically. Re-run with --gui-user.' >&2
      exit 1
    fi
    effective_gui="$GUI_USER"
  fi

  local effective_display
  if [ -n "$display_override" ]; then
    DISPLAY="$display_override"
    effective_display="$display_override"
  else
    auto_detect_display "$effective_gui" || true
    effective_display="${DISPLAY:-:0}"
  fi

  local gui_uid
  gui_uid=$(id -u "$effective_gui")
  local runtime_dir="/run/user/$gui_uid"

  local wayland_display=""
  if [ -d "$runtime_dir" ]; then
    for socket in "$runtime_dir"/wayland-*; do
      [ -S "$socket" ] || continue
      wayland_display=$(basename "$socket")
      break
    done
  fi

  local resolved_script script_dir
  resolved_script=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
  script_dir=$(dirname "$resolved_script")

  mkdir -p "$INSTALL_DIR"
  ensure_script_installed "$resolved_script" "$INSTALL_DIR/kiosk-monitor.sh"

  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_DIR/kiosk-monitor.conf.sample" ] && [ -f "$script_dir/kiosk-monitor.conf.sample" ]; then
    install -m 0644 "$script_dir/kiosk-monitor.conf.sample" "$CONFIG_DIR/kiosk-monitor.conf.sample"
  fi
  ensure_config_file "$url_override" "$gui_override" "$browser_override"

  local service_dependency=""
  local dependency=""
  if dependency=$(tailscaled_dependency_unit); then
    service_dependency="$dependency"
  fi

  write_service_unit "$effective_gui" "$effective_display" "$runtime_dir" "$wayland_display" "$SERVICE_PATH" "$service_dependency"

  systemctl daemon-reload
  if [ "$autostart" = "yes" ]; then
    systemctl enable --now kiosk-monitor.service
    echo 'kiosk-monitor installed and started.'
  else
    systemctl enable kiosk-monitor.service
    echo 'kiosk-monitor installed (service enabled but not started).'
  fi
}

update_self() {
  require_root
  need_cmd systemctl
  need_cmd install

  local gui_override=""
  local display_override=""
  local browser_override=""
  local suppress_restart="no"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --gui-user|--user)
        shift
        gui_override="${1:-}"
        [ -n "$gui_override" ] || { echo 'Error: --gui-user needs a value' >&2; exit 1; }
        ;;
      --display)
        shift
        display_override="${1:-}"
        [ -n "$display_override" ] || { echo 'Error: --display needs a value' >&2; exit 1; }
        ;;
      --browser)
        shift
        browser_override="${1:-}"
        [ -n "$browser_override" ] || { echo 'Error: --browser needs a value' >&2; exit 1; }
        browser_override=$(printf '%s' "$browser_override" | tr '[:upper:]' '[:lower:]')
        ;;
      --no-restart)
        suppress_restart="yes"
        ;;
      --base-url)
        shift
        [ -n "${1:-}" ] || { echo 'Error: --base-url needs a value' >&2; exit 1; }
        echo 'Warning: --base-url is deprecated and ignored.' >&2
        ;;
      *)
        printf 'Error: unknown update option %s\n' "$1" >&2
        usage
        exit 1
        ;;
    esac
    shift
  done

  local was_active="no"
  if systemctl is-active --quiet kiosk-monitor.service; then
    was_active="yes"
  fi

  local effective_gui
  if [ -n "$gui_override" ]; then
    GUI_USER="$gui_override"
    effective_gui="$gui_override"
  else
    if ! auto_detect_gui_user; then
      echo 'Unable to determine GUI user automatically. Re-run with --gui-user.' >&2
      exit 1
    fi
    effective_gui="$GUI_USER"
  fi

  local effective_display
  if [ -n "$display_override" ]; then
    DISPLAY="$display_override"
    effective_display="$display_override"
  else
    auto_detect_display "$effective_gui" || true
    effective_display="${DISPLAY:-:0}"
  fi

  local gui_uid
  gui_uid=$(id -u "$effective_gui")
  local runtime_dir="/run/user/$gui_uid"

  local wayland_display=""
  if [ -d "$runtime_dir" ]; then
    for socket in "$runtime_dir"/wayland-*; do
      [ -S "$socket" ] || continue
      wayland_display=$(basename "$socket")
      break
    done
  fi

  local resolved_script script_dir
  resolved_script=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
  script_dir=$(dirname "$resolved_script")

  mkdir -p "$INSTALL_DIR"
  ensure_script_installed "$resolved_script" "$INSTALL_DIR/kiosk-monitor.sh"

  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_DIR/kiosk-monitor.conf.sample" ] && [ -f "$script_dir/kiosk-monitor.conf.sample" ]; then
    install -m 0644 "$script_dir/kiosk-monitor.conf.sample" "$CONFIG_DIR/kiosk-monitor.conf.sample"
  fi
  if [ -n "$browser_override" ]; then
    ensure_config_file "" "" "$browser_override"
  fi

  local service_dependency=""
  local dependency=""
  if dependency=$(tailscaled_dependency_unit); then
    service_dependency="$dependency"
  fi

  write_service_unit "$effective_gui" "$effective_display" "$runtime_dir" "$wayland_display" "$SERVICE_PATH" "$service_dependency"

  systemctl daemon-reload
  if [ "$was_active" = "yes" ] && [ "$suppress_restart" = "no" ]; then
    systemctl restart kiosk-monitor.service
    echo 'kiosk-monitor updated and restarted.'
  else
    echo 'kiosk-monitor updated.'
  fi
}

remove_self() {
  require_root
  need_cmd systemctl

  local purge="no"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --purge)
        purge="yes"
        ;;
      *)
        printf 'Error: unknown remove option %s\n' "$1" >&2
        usage
        exit 1
        ;;
    esac
    shift
  done

  if systemctl list-unit-files --no-legend | awk '{print $1}' | grep -qx 'kiosk-monitor.service'; then
    systemctl stop kiosk-monitor.service 2>/dev/null || true
    systemctl disable kiosk-monitor.service 2>/dev/null || true
  fi
  rm -f "$SERVICE_PATH"
  rm -f "$INSTALL_DIR/kiosk-monitor.sh"
  if [ "$purge" = "yes" ]; then
    rm -f "$CONFIG_FILE"
    if [ -d "$CONFIG_DIR" ]; then
      rmdir "$CONFIG_DIR" 2>/dev/null || true
    fi
  fi
  systemctl daemon-reload
  echo 'kiosk-monitor removed.'
}

reconfigure_self() {
  require_root
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
  write_effective_config_file "$CONFIG_FILE"
  echo "kiosk-monitor configuration written to $CONFIG_FILE."
}

# ------------------------------------------------------------------------------
# Runtime helper functions
# ------------------------------------------------------------------------------

debug() {
  if [ "$DEBUG" = "true" ]; then
    printf 'DEBUG: %s\n' "$*" >&2
  fi
}

as_gui() {
  if [ "${EUID:-$(id -u)}" -eq "${GUI_UID:-999999}" ] 2>/dev/null; then
    "$@"
  else
    sudo -n -u "$GUI_USER" env XDG_RUNTIME_DIR="/run/user/$GUI_UID" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" DISPLAY="${DISPLAY:-}" "$@"
  fi
}

prepare_profile_runtime() {
  local runtime="$PROFILE_PERSIST_ROOT"
  if [ "$PROFILE_TMPFS" = "true" ]; then
    runtime="${PROFILE_TMPFS_PATH:-/dev/shm/kiosk-monitor}"
    mkdir -p "$runtime"
    chown "$GUI_USER":"$GUI_USER" "$runtime"
    if [ -n "$PROFILE_ARCHIVE" ] && extract_archive "$PROFILE_ARCHIVE" "$runtime"; then
      :
    else
      mirror_tree "$PROFILE_PERSIST_ROOT" "$runtime"
    fi
  else
    mkdir -p "$runtime"
  fi
  PROFILE_RUNTIME_ROOT="$runtime"
  if [ "$PROFILE_TMPFS" = "true" ]; then
    chown -R "$GUI_USER":"$GUI_USER" "$PROFILE_RUNTIME_ROOT"
  else
    chown "$GUI_USER":"$GUI_USER" "$PROFILE_RUNTIME_ROOT"
  fi
}

sync_profile_persist() {
  local final=${1:-false}
  if [ "$PROFILE_TMPFS" = "true" ] && [ "$PROFILE_SYNC_BACK" = "true" ]; then
    mirror_tree "$PROFILE_RUNTIME_ROOT" "$PROFILE_PERSIST_ROOT"
  fi
  if [ "$final" = "true" ] && [ "$PROFILE_TMPFS" = "true" ] && [ "$PROFILE_TMPFS_PURGE" = "true" ]; then
    rm -rf "$PROFILE_RUNTIME_ROOT"
  fi
}

gui_session_active() {
  if ! command -v loginctl >/dev/null 2>&1; then
    return 0
  fi
  if loginctl show-user "$GUI_USER" -p Sessions --value 2>/dev/null | grep -q '[^[:space:]]'; then
    return 0
  fi
  if loginctl list-sessions --no-legend 2>/dev/null | awk -v user="$GUI_USER" '$3 == user { found=1; exit 0 } END { exit (found?0:1) }'; then
    return 0
  fi
  return 1
}

wait_for_gui_session() {
  local timeout="$GUI_SESSION_WAIT_TIMEOUT"
  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [ "$timeout" -le 0 ]; then
    return
  fi
  if ! command -v loginctl >/dev/null 2>&1; then
    return
  fi
  if gui_session_active; then
    return
  fi
  echo "Waiting for GUI session for $GUI_USER (timeout ${timeout}s)…"
  local waited=0
  while [ "$waited" -lt "$timeout" ]; do
    sleep 1
    waited=$((waited + 1))
    if gui_session_active; then
      echo "GUI session detected for $GUI_USER."
      return
    fi
  done
  echo "GUI session for $GUI_USER not detected after ${timeout}s; continuing." >&2
}

ensure_birdseye_extension() {
  if [ "$BROWSER_FLAVOR" != "chromium" ]; then
    return
  fi
  if [ "$BIRDSEYE_AUTO_FILL" != "true" ]; then
    return
  fi
  local -a candidates=()
  if [ -n "${BIRDSEYE_EXTENSION_DIR:-}" ]; then
    candidates+=( "${BIRDSEYE_EXTENSION_DIR%/}" )
  fi
  candidates+=( "${PROFILE_RUNTIME_ROOT%/}/birdseye-autofill" "/usr/local/share/kiosk-monitor/birdseye-autofill" )
  local dir=""
  local configured_dir="${BIRDSEYE_EXTENSION_DIR:-}"
  for candidate in "${candidates[@]}"; do
    [ -n "$candidate" ] || continue
    if mkdir -p "$candidate" 2>/dev/null; then
      dir="$candidate"
      break
    fi
  done
  if [ -z "$dir" ]; then
    printf 'Error: could not create Birdseye extension directories (tried: %s)\n' "${candidates[*]}" >&2
    return
  fi
  if [ -n "$configured_dir" ]; then
    local normalized_configured="${configured_dir%/}"
    if [ "$dir" != "$normalized_configured" ]; then
      printf 'Warning: unable to write Birdseye extension to %s; using %s instead\n' "$normalized_configured" "$dir" >&2
    fi
  fi
  local match_pattern="${BIRDSEYE_MATCH_PATTERN:-}"
  if [ -z "$match_pattern" ]; then
    match_pattern=$(derive_match_pattern "$URL")
  fi
  local css_file="$dir/fullscreen.css"
  local manifest_file="$dir/manifest.json"
  cat > "$css_file" <<'EOF'

/* 1. Set the width and height for the birdseye grid container */
#pageRoot > div > div > div > div.react-grid-layout.grid-layout {
  height: 1000px !important; /* Ensure height is correct */
  width: 100% !important; /* Allow it to stretch to 100% width of its parent */
  max-width: 1800px !important; /* Max width at 1800px */
  margin: 0 auto; /* Center the container if needed */
}

/* 2. Set the width and height for the canvas element */
#pageRoot > div > div > div > div.react-grid-layout.grid-layout > div > div > div.size-full > div > div > div > canvas {
  height: 1000px !important; /* Ensure canvas height is fixed */
  width: 100% !important; /* Make the canvas take up the full width of its container */
}

/* 3. Ensure parent containers are flexible enough to accommodate the canvas width */
#pageRoot > div > div > div > div.react-grid-layout.grid-layout > div {
  display: flex;
  flex-direction: column;
  width: 100% !important;
  max-width: 1800px !important;
}

/* Optional: Make the viewport fully responsive based on viewport size */
#pageRoot > div > div > div > div.react-grid-layout.grid-layout {
  width: 100vw !important;  /* Ensure it's responsive to viewport width */
  height: 100vh !important; /* Fill the entire height of the viewport */
}

/* 6) Explicit canvas sizing for Frigate Birdseye widgets */
#pageRoot > div > div > div > div.react-grid-layout.grid-layout {
  height: 1000px !important;
  width: 1800px !important;
}

#pageRoot > div > div > div > div.react-grid-layout.grid-layout > div > div > div.size-full > div > div > div > canvas {
  height: 1000px !important;
  width: 1800px !important;
}

EOF
  cat > "$manifest_file" <<EOF
{
  "name": "Frigate Birdseye Auto-Fill",
  "version": "1.0",
  "manifest_version": 3,
  "description": "Ensure the Frigate Birdseye grid fills the window and hides the resize handle.",
  "content_scripts": [
    {
      "matches": ["$match_pattern"],
      "css": ["fullscreen.css"],
      "run_at": "document_start"
    }
  ]
}
EOF
  chmod 0644 "$css_file" "$manifest_file"
  chmod 0755 "$dir"
  chown -R "$GUI_USER":"$GUI_USER" "$dir" 2>/dev/null || true
  BIRDSEYE_EXTENSION_PATH="$dir"
}

start_profile_sync_timer() {
  if [ "$PROFILE_TMPFS" != "true" ]; then
    return
  fi
  if [ "$PROFILE_SYNC_BACK" != "true" ]; then
    return
  fi
  if ! [[ "$PROFILE_SYNC_INTERVAL" =~ ^[0-9]+$ ]] || [ "$PROFILE_SYNC_INTERVAL" -le 0 ]; then
    return
  fi
  (
    while true; do
      sleep "$PROFILE_SYNC_INTERVAL" || break
      sync_profile_persist
    done
  ) &
  PROFILE_SYNC_PID=$!
}

stop_other_browser_sessions() {
  local keep_pid=${1:-}
  local tries=0
  while [ $tries -lt 3 ]; do
    local pattern=""
    if [ -n "${CHROMIUM_BROWSER_MATCH:-}" ]; then
      pattern="$CHROMIUM_BROWSER_MATCH"
    elif [ -n "${CHROMIUM_PGREP_PATTERN:-}" ]; then
      pattern="$CHROMIUM_PGREP_PATTERN"
    else
      pattern="--type=browser"
    fi
    mapfile -t main_pids < <(pgrep -u "$GUI_USER" -f -- "$pattern" 2>/dev/null || true)
    local terminated=0
    for pid in "${main_pids[@]}"; do
      [ -n "$pid" ] || continue
      if [ -n "$keep_pid" ] && [ "$pid" = "$keep_pid" ]; then
        continue
      fi
      if kill -0 "$pid" 2>/dev/null; then
        printf 'Pruning stray %s browser PID %s\n' "$BROWSER_LABEL" "$pid"
        kill "$pid" 2>/dev/null || true
        terminated=1
      fi
    done
    if [ $terminated -eq 0 ]; then
      break
    fi
    sleep 1
    tries=$((tries + 1))
  done

  if [ -n "$keep_pid" ] && ! kill -0 "$keep_pid" 2>/dev/null; then
    keep_pid=""
  fi

  if [ -n "${CHROMIUM_BROWSER_MATCH:-}" ]; then
    mapfile -t dupes < <(pgrep -u "$GUI_USER" -f -- "${CHROMIUM_BROWSER_MATCH}" 2>/dev/null || true)
  elif [ -n "${CHROMIUM_PGREP_PATTERN:-}" ]; then
    mapfile -t dupes < <(pgrep -u "$GUI_USER" -f -- "${CHROMIUM_PGREP_PATTERN}" 2>/dev/null || true)
  else
    mapfile -t dupes < <(pgrep -u "$GUI_USER" -f -- "--type=browser" 2>/dev/null || true)
  fi
  if [ "${#dupes[@]}" -gt 1 ]; then
    for pid in "${dupes[@]}"; do
      [ -n "$pid" ] || continue
      if [ -n "$keep_pid" ] && [ "$pid" = "$keep_pid" ]; then
        continue
      fi
      kill -9 "$pid" 2>/dev/null || true
    done
    sleep 1
  fi

  force_ps_browser_cleanup "$keep_pid"
}

force_ps_browser_cleanup() {
  local keep_pid=${1:-}
  local keyword
  keyword="$(basename "$CHROME")"
  if [ -z "$keyword" ]; then
    keyword="chromium"
  fi

  need_cmd ps

  local -a ps_pids=()
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    ps_pids+=( "$pid" )
  done < <(ps -eo user=,pid=,command= | awk -v user="$GUI_USER" -v keep="$keep_pid" -v keyword="$keyword" '
    $1 == user && index($0, keyword) { print $2 }
  ')

  local killed=0
  for pid in "${ps_pids[@]}"; do
    if [ -n "$keep_pid" ] && [ "$pid" = "$keep_pid" ]; then
      continue
    fi
    if kill -0 "$pid" 2>/dev/null; then
      debug "Force-killing lingering $BROWSER_LABEL PID $pid (ps fallback)"
      kill -9 "$pid" 2>/dev/null || true
      killed=1
    fi
  done

  if [ "$killed" -eq 1 ]; then
    sleep 1
  fi
}

patch_prefs() {
  mkdir -p "$PROFILE_DIR"
  local pref="$PROFILE_PREFS"
  local local_state="$PROFILE_ROOT/Local State"

  if [ ! -f "$pref" ]; then
    printf '{}\n' > "$pref"
  fi

  if command -v python3 >/dev/null 2>&1; then
    PREF_PATH="$pref" STATE_PATH="$local_state" TARGET_URL="$URL" python3 <<'PYTHON'
import json
import os

def load_json(path):
    try:
        with open(path, 'r', encoding='utf-8') as fh:
            return json.load(fh)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError:
        return {}

pref_path = os.environ['PREF_PATH']
state_path = os.environ['STATE_PATH']
target_url = os.environ.get('TARGET_URL', '')

prefs = load_json(pref_path)
profile = prefs.setdefault('profile', {})
profile['exit_type'] = 'Normal'
profile['exited_cleanly'] = True

session = prefs.setdefault('session', {})
session['restore_on_startup'] = 0
session['startup_urls'] = []
session['urls_to_restore_on_startup'] = []
session['recently_closed_tabs'] = []

browser = prefs.setdefault('browser', {})
browser['last_opened_urls'] = [target_url] if target_url else []
browser['show_home_button'] = False
browser['check_default_browser'] = False

distribution = prefs.setdefault('distribution', {})
distribution['show_welcome_page'] = False
distribution['skip_first_run_ui'] = True

with open(pref_path, 'w', encoding='utf-8') as fh:
    json.dump(prefs, fh, indent=2, sort_keys=True)

state = load_json(state_path)
state_profile = state.setdefault('profile', {})
state_profile['exit_type'] = 'Normal'
state_profile.setdefault('last_used', 'Default')

with open(state_path, 'w', encoding='utf-8') as fh:
    json.dump(state, fh, indent=2, sort_keys=True)
PYTHON
  else
    sed -i -E \
      -e 's/"exited_cleanly":[[:space:]]*false/"exited_cleanly":true/g' \
      -e 's/"exit_type":[[:space:]]*"Crashed"/"exit_type":"Normal"/g' \
      "$pref"
  fi

  find "$PROFILE_DIR" -maxdepth 1 -type f \
    \( -name 'Current *' -o -name 'Last *' -o -name 'Singleton*' -o -name 'Tabs_*' \) \
    -delete -print |
    while read -r f; do echo "  removed $(basename "$f")"; done

  rm -rf "$PROFILE_DIR/Sessions" "$PROFILE_DIR/Session Storage" 2>/dev/null || true
  rm -f "$PROFILE_DIR"/Singleton* "$PROFILE_ROOT"/Singleton* 2>/dev/null || true

  trim_chromium_cache
  chown -R "$GUI_USER":"$GUI_USER" "$PROFILE_ROOT"
}

health_check() {
  local connect="${HEALTH_CONNECT_TIMEOUT:-2}"
  local total="${HEALTH_TOTAL_TIMEOUT:-6}"
  local code cmd label

  for mode in head get; do
    if [ "$mode" = "head" ]; then
      cmd=(curl -sS -I --connect-timeout "$connect" --max-time "$total" -o /dev/null -w "%{http_code}" "$URL")
      label="HEAD"
    else
      cmd=(curl -sS --connect-timeout "$connect" --max-time "$total" -o /dev/null -w "%{http_code}" "$URL")
      label="GET"
    fi
    code=$("${cmd[@]}" 2>/dev/null || echo 000)
    debug "health_check ${label} HTTP code=$code"
    if [ "$code" -ge 200 ] && [ "$code" -lt 400 ]; then
      return 0
    fi
  done
  echo "Health check failed for $URL (last HTTP $code) at $(date)" >&2
  return 1
}

wait_for_url_ready() {
  local timeout="${WAIT_FOR_URL_TIMEOUT:-0}"
  local waited=0
  while true; do
    if health_check; then
      echo "Target $URL is reachable at $(date) — continuing."
      return 0
    fi
    echo "  still down at $(date)"
    sleep 1
    waited=$((waited + 1))
    if [ "$timeout" -gt 0 ] && [ "$waited" -ge "$timeout" ]; then
      echo "Health check still failing after ${timeout}s — continuing anyway." >&2
      return 1
    fi
  done
}

capture_hash() {
  local checksum=""
  local capture_tmp=""
  capture_tmp=$(mktemp 2>/dev/null) || return 1

  local -a cmd=()
  if [ "$BACKEND" = "wayland" ]; then
    cmd=(as_gui grim "${GRIM_OUT_OPT[@]}" -t ppm - -)
    debug "Capturing Wayland frame via grim for freeze detection (mode=$SCREEN_SAMPLE_MODE)"
  else
    cmd=(as_gui xwd -silent -root -display "$DISPLAY")
    debug "Capturing X11 frame via xwd for freeze detection (mode=$SCREEN_SAMPLE_MODE)"
  fi

  if ! "${cmd[@]}" >"$capture_tmp" 2>/dev/null; then
    debug "capture_hash: screenshot command failed"
    rm -f "$capture_tmp"
    return 1
  fi

  if command -v python3 >/dev/null 2>&1; then
    local python_hash_status=0
    checksum=$(
      HASH_MODE="$SCREEN_SAMPLE_MODE" python3 - "$capture_tmp" <<'PYTHON'
import hashlib
import os
import struct
import sys

MODE = os.environ.get("HASH_MODE", "sample").strip().lower()
if MODE not in ("sample", "full"):
    MODE = "sample"

def half_or_full(value):
    if MODE == "full":
        return value
    return value // 2 if value > 1 else value

def hash_ppm(path):
    with open(path, "rb") as fh:
        magic = fh.read(2)
        if magic != b"P6":
            return None

        def read_token():
            token = bytearray()
            while True:
                ch = fh.read(1)
                if not ch:
                    return None
                if ch == b"#":
                    fh.readline()
                    continue
                if ch in b" \t\r\n":
                    if token:
                        return token.decode("ascii")
                    continue
                token.append(ch[0])

        def skip_to_data():
            while True:
                ch = fh.read(1)
                if not ch:
                    return
                if ch not in b" \t\r\n":
                    fh.seek(-1, 1)
                    return

        width_token = read_token()
        height_token = read_token()
        maxval_token = read_token()
        if not width_token or not height_token or not maxval_token:
            return None
        width = int(width_token)
        height = int(height_token)
        maxval = int(maxval_token)
        if width <= 0 or height <= 0:
            return None
        bytes_per_channel = 2 if maxval > 255 else 1
        skip_to_data()
        region_w = half_or_full(width)
        region_h = half_or_full(height)
        row_bytes = width * 3 * bytes_per_channel
        region_bytes = region_w * 3 * bytes_per_channel
        hasher = hashlib.sha256()
        for row in range(height):
            row_data = fh.read(row_bytes)
            if len(row_data) != row_bytes:
                return None
            if row < region_h:
                hasher.update(row_data[:region_bytes])
        return hasher.hexdigest()

def hash_xwd(path):
    with open(path, "rb") as fh:
        header = fh.read(100)
        if len(header) != 100:
            return None
        values = None
        endian = None
        for fmt in ("<", ">"):
            try:
                candidate = struct.unpack(fmt + "25I", header)
            except struct.error:
                continue
            header_size = candidate[0]
            width = candidate[4]
            height = candidate[5]
            bytes_per_line = candidate[12]
            ncolors = candidate[19]
            bits_per_pixel = candidate[11]
            if (
                100 <= header_size <= 65536
                and 0 < width <= 20000
                and 0 < height <= 12000
                and 0 < bytes_per_line <= 163840
            ):
                values = candidate
                endian = fmt
                break
        if values is None:
            return None

        header_size = values[0]
        width = values[4]
        height = values[5]
        bits_per_pixel = values[11]
        bytes_per_line = values[12]
        ncolors = values[19]

        remaining = header_size - 100
        if remaining < 0:
            return None
        if remaining:
            skipped = fh.read(remaining)
            if len(skipped) != remaining:
                return None

        color_entry_size = 12
        cmap_bytes = ncolors * color_entry_size
        if cmap_bytes:
            skipped = fh.read(cmap_bytes)
            if len(skipped) != cmap_bytes:
                return None

        bytes_per_pixel = max(1, (bits_per_pixel + 7) // 8)
        region_w = half_or_full(width)
        region_h = half_or_full(height)
        region_bytes = min(bytes_per_line, region_w * bytes_per_pixel)
        hasher = hashlib.sha256()
        for row in range(height):
            row_data = fh.read(bytes_per_line)
            if len(row_data) != bytes_per_line:
                return None
            if row < region_h:
                hasher.update(row_data[:region_bytes])
        return hasher.hexdigest()

def main():
    path = sys.argv[1]
    digest = hash_ppm(path)
    if digest is None:
        digest = hash_xwd(path)
    if digest is None:
        raise SystemExit(1)
    print(digest)

if __name__ == "__main__":
    main()
PYTHON
    )
    python_hash_status=$?
    checksum=$(printf '%s' "$checksum" | tr -d '[:space:]')
    if [ $python_hash_status -ne 0 ]; then
      checksum=""
    fi
  fi

  if [ -z "$checksum" ]; then
    debug "capture_hash: falling back to simple byte hashing"
    if [ "$SCREEN_SAMPLE_MODE" = "full" ]; then
      checksum=$(sha256sum "$capture_tmp" 2>/dev/null | awk '{print $1}')
    else
      checksum=$(
        head -c "$SCREEN_SAMPLE_BYTES" "$capture_tmp" 2>/dev/null | sha256sum | awk '{print $1}'
      )
    fi
  fi

  rm -f "$capture_tmp"

  if [ -z "$checksum" ]; then
    debug "capture_hash: no checksum computed (mode=$SCREEN_SAMPLE_MODE)"
    return 1
  fi
  debug "Computed hash: $checksum"
  printf '%s\n' "$checksum"
}

record_restart() {
  stop_browser
  now=$(date +%s)
  debug "Recording restart at $now (window size=${#restart_times[@]})"
  restart_times=( "${restart_times[@]}" "$now" )
  while (( ${#restart_times[@]} > 0 && now - restart_times[0] > RESTART_WINDOW )); do
    restart_times=( "${restart_times[@]:1}" )
  done
  if [ "${#restart_times[@]}" -gt "$MAX_RESTARTS" ]; then
    echo ">>> Too many restarts ($MAX_RESTARTS) in the last ${RESTART_WINDOW}s" >&2
    echo "sleeping for 5 minutes before retry…" >&2
    sleep 300
    restart_times=()
  fi
  start_browser
  if health_check; then
    consecutive_failures=0
  fi
}

start_browser() {
  need_cmd "$CHROME"
  maybe_defer_launch
  stop_other_browser_sessions
  patch_prefs
  local -a extra_flags=()
  if [ "$BACKEND" = "wayland" ]; then
    extra_flags+=( --enable-features=UseOzonePlatform --ozone-platform=wayland )
  fi
  if [ "$BIRDSEYE_AUTO_FILL" = "true" ]; then
    ensure_birdseye_extension
    if [ -n "${BIRDSEYE_EXTENSION_PATH:-}" ]; then
      extra_flags+=( "--load-extension=$BIRDSEYE_EXTENSION_PATH" "--disable-extensions-except=$BIRDSEYE_EXTENSION_PATH" )
    fi
  fi
  debug "Starting $BROWSER_LABEL with flags: ${FLAGS[*]} ${extra_flags[*]}"
  local launcher=("$CHROME")
  as_gui "${launcher[@]}" "${extra_flags[@]}" "${FLAGS[@]}" > /dev/null 2>&1 &
  debug "Launched $BROWSER_LABEL…"
  sleep "$CHROME_LAUNCH_DELAY_SECONDS"

  LAUNCHER_PID=$!
  sleep "$CHROME_READY_DELAY_SECONDS"
  if [ -n "${CHROMIUM_BROWSER_MATCH:-}" ]; then
    BROWSER_PID=$(pgrep -u "$GUI_USER" -o -f -- "${CHROMIUM_BROWSER_MATCH}" || true)
  elif [ -n "${CHROMIUM_PGREP_PATTERN:-}" ]; then
    BROWSER_PID=$(pgrep -u "$GUI_USER" -o -f -- "${CHROMIUM_PGREP_PATTERN}" || true)
  else
    BROWSER_PID=$(pgrep -u "$GUI_USER" -o -f -- "--type=browser" || true)
  fi
  if [ -z "$BROWSER_PID" ] && kill -0 "$LAUNCHER_PID" 2>/dev/null; then
    BROWSER_PID=$(pgrep -P "$LAUNCHER_PID" -n || echo "$LAUNCHER_PID")
  fi
  BROWSER_PID=${BROWSER_PID:-$LAUNCHER_PID}
  echo "$BROWSER_LABEL main PID is $BROWSER_PID (launcher $LAUNCHER_PID)"
}

stop_browser() {
  if [ -n "$BROWSER_PID" ] && kill -0 "$BROWSER_PID" 2>/dev/null; then
    debug "Stopping $BROWSER_LABEL PID=$BROWSER_PID"
    printf 'Stopping %s PID %s…\n' "$BROWSER_LABEL" "$BROWSER_PID"
    kill "$BROWSER_PID"
    wait "$BROWSER_PID" 2>/dev/null || true
    BROWSER_PID=""
  else
    BROWSER_PID=""
  fi
}

handle_shutdown_signal() {
  if [ "$SHUTDOWN_REQUESTED" = "true" ]; then
    return
  fi
  SHUTDOWN_REQUESTED=true
  printf 'Termination signal received — shutting down kiosk-monitor.\n'
  stop_browser
  force_ps_browser_cleanup
  exit 0
}

cleanup() {
  local status=$?
  trap - EXIT
  stop_browser
  force_ps_browser_cleanup
  if [ -n "$PROFILE_SYNC_PID" ]; then
    if kill -0 "$PROFILE_SYNC_PID" 2>/dev/null; then
      kill "$PROFILE_SYNC_PID" 2>/dev/null || true
    fi
    wait "$PROFILE_SYNC_PID" 2>/dev/null || true
  fi
  sync_profile_persist true
  flock -u 200 2>/dev/null || true
  exec 200>&- 2>/dev/null || true
  printf '==== STOP %s at %s ====\n' "$0" "$(date -Is)"
  exit $status
}

case "$ACTION" in
  install)
    install_self "${ACTION_ARGS[@]}"
    exit 0
    ;;
  update)
    update_self "${ACTION_ARGS[@]}"
    exit 0
    ;;
  remove)
    remove_self "${ACTION_ARGS[@]}"
    exit 0
    ;;
  reconfig)
    reconfigure_self
    exit 0
    ;;
  help)
    usage
    exit 0
    ;;
  version)
    echo "$SCRIPT_VERSION"
    exit 0
    ;;
esac

set -- "${ACTION_ARGS[@]}"

DEBUG=${DEBUG:-false}
for arg in "$@"; do
  if [ "$arg" = "--debug" ]; then
    DEBUG=true
    # strip the flag so it doesn't interfere with any future arg parsing
    set -- "${@/--debug/}"
    break
  fi
done

# ——— Logging ———
# Default to RAM to reduce SD wear; can override via env LOG=/path/file
LOG_DEFAULT="/dev/shm/kiosk.log"
LOG="${LOG:-$LOG_DEFAULT}"
requested_log="$LOG"
if ! init_log_file "$LOG"; then
  fallback_log="/tmp/kiosk-monitor-${UID}.log"
  if init_log_file "$fallback_log"; then
    if [ "$requested_log" != "$fallback_log" ]; then
      printf 'Warning: unable to write to %s; logging to %s instead\n' "$requested_log" "$fallback_log" >&2
    fi
    LOG="$fallback_log"
  else
    printf 'Error: could not initialise log file at %s or %s\n' "$requested_log" "$fallback_log" >&2
    exit 1
  fi
fi
# Duplicate all stdout/stderr to both console and logfile
exec > >(tee -a "$LOG") 2>&1
need_cmd curl
need_cmd flock
need_cmd sha256sum
requested_lock="$LOCK_FILE"
if ! open_lock_file "$requested_lock"; then
  fallback_base="${XDG_RUNTIME_DIR:-}"
  if [ -n "$fallback_base" ]; then
    if ! mkdir -p "$fallback_base" 2>/dev/null; then
      fallback_base=""
    fi
  fi
  if [ -z "$fallback_base" ]; then
    fallback_base="/tmp"
  fi
  lock_fallback="${fallback_base%/}/kiosk-monitor-${UID}.lock"
  if open_lock_file "$lock_fallback"; then
    if [ "$requested_lock" != "$lock_fallback" ]; then
      printf 'Warning: unable to acquire lock at %s; using %s\n' "$requested_lock" "$lock_fallback" >&2
    fi
  else
    printf 'Error: could not create lock file at %s or %s\n' "$requested_lock" "$lock_fallback" >&2
    exit 1
  fi
fi
if ! flock -n 200; then
  echo "Another kiosk-monitor instance is already running (lock $LOCK_FILE)." >&2
  exit 0
fi

if [ "$DEBUG" = "true" ]; then
  set -x
fi

ensure_minimum_uptime

# ----- User / session info -----
# Prefer pre-set GUI_USER (e.g., from systemd unit). Otherwise, try loginctl.
if [ -z "${GUI_USER:-}" ]; then
  if command -v loginctl >/dev/null 2>&1; then
    GUI_USER=$(loginctl show-session "$(loginctl list-sessions --no-legend | awk '$3=="seat0" {print $1; exit}')" -p Name --value 2>/dev/null || true)
  fi
  # Fallback to SUDO_USER if available (but never fall back to root for GUI)
  if [ -z "$GUI_USER" ] || [ "$GUI_USER" = "root" ]; then
    GUI_USER="${SUDO_USER:-}"
  fi
  if [ -z "$GUI_USER" ] || [ "$GUI_USER" = "root" ]; then
    if [ "${EUID:-$(id -u)}" -ne 0 ] && [ -n "${USER:-}" ] && [ "$USER" != "root" ]; then
      GUI_USER="$USER"
    fi
  fi
  if [ -z "$GUI_USER" ] || [ "$GUI_USER" = "root" ]; then
    echo "No valid GUI user detected (not in a graphical session). Set GUI_USER= in the service env." >&2
    exit 1
  fi
fi
GUI_UID=$(id -u "$GUI_USER")
wait_for_gui_session
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  chown "$GUI_USER":"$GUI_USER" "$LOG" 2>/dev/null || true
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${GUI_UID}}"
if [ ! -d "$XDG_RUNTIME_DIR" ] && [ "${EUID:-$(id -u)}" -eq 0 ]; then
  mkdir -p "$XDG_RUNTIME_DIR"
  chown "$GUI_USER":"$GUI_USER" "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"
elif [ ! -d "$XDG_RUNTIME_DIR" ]; then
  echo "Warning: XDG_RUNTIME_DIR $XDG_RUNTIME_DIR does not exist; display detection may fail." >&2
fi

PROFILE_PERSIST_ROOT="${PROFILE_ROOT:-/home/${GUI_USER}/.local/share/kiosk-monitor}"
PROFILE_RUNTIME_ROOT="$PROFILE_PERSIST_ROOT"

prepare_profile_runtime
start_profile_sync_timer

PROFILE_ROOT="$PROFILE_RUNTIME_ROOT"
profile_regex=$(regex_escape "$PROFILE_ROOT")
CHROMIUM_PGREP_PATTERN="--user-data-dir=$profile_regex"
CHROMIUM_BROWSER_MATCH="--type=browser"
PROFILE_DIR="$PROFILE_ROOT/Default"
PROFILE_PREFS="$PROFILE_DIR/Preferences"
mkdir -p "$PROFILE_DIR"

BROWSER_PID=""
SKIP_HEALTH_LOOP=false

URL="${URL:-$DEFAULT_URL}"
FLAGS=(
  --kiosk
  --start-fullscreen
  --no-first-run
  --no-default-browser-check
  --disable-restore-session-state
  --disable-translate
  --disable-infobars
  --disable-session-crashed-bubble
  '--disable-features=TranslateUI,ChromeWhatsNewUI'
  --disable-component-update
  --disable-sync
  --noerrdialogs
  --disable-logging
  --disable-logging-redirect
  --log-level=3
  --enable-features=OverlayScrollbar
  --password-store=basic
  --allow-running-insecure-content
  --user-data-dir="$PROFILE_ROOT"
  --new-window
  "$URL"
)
if [ "$DEVTOOLS_AUTO_OPEN" = "true" ]; then
  FLAGS+=( --auto-open-devtools-for-tabs )
fi
if [ -n "$DEVTOOLS_REMOTE_PORT" ]; then
  FLAGS+=( "--remote-debugging-port=$DEVTOOLS_REMOTE_PORT" )
fi

# ——— Environment ———
if [ -z "${DISPLAY:-}" ]; then
  if command -v loginctl >/dev/null 2>&1; then
    GUI_DISPLAY=$(loginctl show-user "$GUI_USER" -p Display --value 2>/dev/null || true)
  fi
  export DISPLAY=":${GUI_DISPLAY:-0}"
fi
export XAUTHORITY="/home/${GUI_USER}/.Xauthority"

# Ensure Wayland session vars exist (if Wayland is active)
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
  if shopt -q nullglob 2>/dev/null; then
    saved_nullglob=1
  else
    saved_nullglob=0
    shopt -s nullglob 2>/dev/null || true
  fi
  for candidate in "$XDG_RUNTIME_DIR"/wayland-*; do
    if [ -S "$candidate" ]; then
      WAYLAND_DISPLAY=$(basename "$candidate")
      export WAYLAND_DISPLAY
      break
    fi
  done
  if [ "$saved_nullglob" -eq 0 ]; then
    shopt -u nullglob 2>/dev/null || true
  fi
fi

# Identify whether we're on Wayland or X11
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
  BACKEND="wayland"
else
  BACKEND="x11"
fi
printf 'Display backend detected: %s (%s)\n' "$BACKEND" "$(date -Is)"
debug "Backend=$BACKEND"

trap cleanup EXIT
trap handle_shutdown_signal INT TERM
printf '==== START %s at %s ====\n' "$0" "$(date -Is)"

# ——— Initial browser detection and launch ———
if [ -n "${CHROMIUM_BROWSER_MATCH:-}" ]; then
  existing_pid=$(pgrep -u "$GUI_USER" -o -f -- "${CHROMIUM_BROWSER_MATCH}" || true)
elif [ -n "${CHROMIUM_PGREP_PATTERN:-}" ]; then
  existing_pid=$(pgrep -u "$GUI_USER" -o -f -- "${CHROMIUM_PGREP_PATTERN}" || true)
else
  existing_pid=$(pgrep -u "$GUI_USER" -o -f -- "--type=browser" || true)
fi
if [ -n "$existing_pid" ]; then
  BROWSER_PID=$existing_pid
  stop_other_browser_sessions "$BROWSER_PID"
  proc_age=$(ps -p "$BROWSER_PID" -o etimes= --no-headers | tr -d ' ')
  printf '%s already running (PID %s), skipping initial launch\n' "$BROWSER_LABEL" "$BROWSER_PID"
  # Ensure server is responding at least once
  if ! health_check; then
    echo "Initial health check failed, waiting for server... ($(date))"
    wait_for_url_ready
  fi
  # Seed last_hash so display‐stall checking begins immediately
  last_hash=$(capture_hash)
  stall_count=0
  SKIP_HEALTH_LOOP=true
else
  if [ "$WAIT_FOR_URL" = "true" ]; then
    printf 'Waiting for %s …\n' "$URL"
    wait_for_url_ready
  else
    echo "Skipping initial reachability wait (WAIT_FOR_URL=false)"
  fi

  # Kick off the browser
  start_browser
  # Seed last_hash after fresh launch
  last_hash=$(capture_hash)
  stall_count=0
  SKIP_HEALTH_LOOP=false
fi

# ——— Watchdog loop ———
# stall_count already seeded above
consecutive_failures=0
restart_times=()          # ring‑buffer for storm protection
last_good=$(date +%s)
# CLEAN_RESET controls how long a healthy run resets restart history

while true; do

  debug "Watchdog loop iteration: ${BROWSER_LABEL}_PID=$BROWSER_PID, consecutive_failures=$consecutive_failures, stall_count=$stall_count"

  # 1) Did the browser disappear?
  if ! kill -0 "$BROWSER_PID" 2>/dev/null; then
    echo "$BROWSER_LABEL main PID $BROWSER_PID vanished — restarting…"
    record_restart
    continue
  fi

  active_pattern=""
  if [ -n "${CHROMIUM_BROWSER_MATCH:-}" ]; then
    active_pattern="${CHROMIUM_BROWSER_MATCH}"
  elif [ -n "${CHROMIUM_PGREP_PATTERN:-}" ]; then
    active_pattern="${CHROMIUM_PGREP_PATTERN}"
  else
    active_pattern="--type=browser"
  fi
  mapfile -t active_browsers < <(pgrep -u "$GUI_USER" -f -- "$active_pattern" 2>/dev/null || true)
  if [ "${#active_browsers[@]}" -gt 1 ]; then
    echo "Detected multiple $BROWSER_LABEL processes — pruning extras"
    stop_other_browser_sessions "$BROWSER_PID"
    if [ -n "${CHROMIUM_BROWSER_MATCH:-}" ]; then
      BROWSER_PID=$(pgrep -u "$GUI_USER" -o -f -- "${CHROMIUM_BROWSER_MATCH}" || true)
    elif [ -n "${CHROMIUM_PGREP_PATTERN:-}" ]; then
      BROWSER_PID=$(pgrep -u "$GUI_USER" -o -f -- "${CHROMIUM_PGREP_PATTERN}" || true)
    else
      BROWSER_PID=$(pgrep -u "$GUI_USER" -o -f -- "--type=browser" || true)
    fi
    if [ -z "$BROWSER_PID" ] && kill -0 "$LAUNCHER_PID" 2>/dev/null; then
      BROWSER_PID=$(pgrep -P "$LAUNCHER_PID" -n || true)
    fi
    if [ -z "$BROWSER_PID" ]; then
      echo "All $BROWSER_LABEL processes terminated; restarting"
      record_restart
      continue
    fi
  fi

  # 2) Probe the dashboard (skipped if attached to existing browser)
  if [ "${SKIP_HEALTH_LOOP:-false}" = "false" ]; then
    if health_check; then
      consecutive_failures=0
      last_good=$(date +%s)
    else
      consecutive_failures=$((consecutive_failures + 1))
      echo "Health check failed ($consecutive_failures/${HEALTH_RETRIES}) at $(date)"
    fi
  else
    debug "Skipping health check (attached to existing $BROWSER_LABEL)"
  fi

  # 3) Screen-change check (trigger when browser process is older than SCREEN_DELAY)
  proc_age=$(ps -p "$BROWSER_PID" -o etimes= --no-headers | awk '{print $1}')
  debug "$BROWSER_LABEL process age=${proc_age}s (SCREEN_DELAY=${SCREEN_DELAY}s)"
  if [ "$proc_age" -ge "$SCREEN_DELAY" ]; then
    debug "Proc age ($proc_age) ≥ SCREEN_DELAY ($SCREEN_DELAY): running visual check"
    curr_hash=$(capture_hash)
    if [ -z "$curr_hash" ]; then
      echo "ERROR: capture_hash returned no data—skipping this cycle" >&2
      sleep "$HEALTH_INTERVAL"
      continue
    fi
    if [ -n "$last_hash" ] && [ "$curr_hash" = "$last_hash" ]; then
      stall_count=$((stall_count + 1))
      echo "Screen unchanged for $stall_count/${STALL_RETRIES} cycles at $(date)"
    else
      stall_count=0
      last_hash="$curr_hash"
    fi
  fi

  # reset restart history after long healthy period
  if [ $(( $(date +%s) - last_good )) -gt "$CLEAN_RESET" ]; then
    restart_times=()
  fi

  if [ "$stall_count" -ge "$STALL_RETRIES" ]; then
    echo "Screen appears frozen — restarting $BROWSER_LABEL..."
    stall_count=0
    record_restart
    continue
  fi

  # 4) Restart if the threshold is breached
  if [ "$consecutive_failures" -ge "$HEALTH_RETRIES" ]; then
    echo "Failure threshold reached — restarting $BROWSER_LABEL…"
    consecutive_failures=0
    record_restart
  fi

  sleep "$HEALTH_INTERVAL"
done
# Ensure the system has been up long enough before we start touching GUI/session state.
ensure_minimum_uptime() {
  local min="$MIN_UPTIME_BEFORE_START"
  if ! [[ "$min" =~ ^[0-9]+$ ]] || [ "$min" -le 0 ]; then
    return
  fi
  local elapsed=0
  if [ -r /proc/uptime ]; then
    elapsed=$(awk '{printf "%d\n",$1}' /proc/uptime 2>/dev/null || echo 0)
  fi
  if [ "$elapsed" -ge "$min" ]; then
    return
  fi
  local wait=$((min - elapsed))
  if [ "$wait" -le 0 ]; then
    wait=60
  fi
  echo "System uptime ${elapsed}s < ${min}s — sleeping ${wait}s before kiosk start."
  sleep "$wait"
}
