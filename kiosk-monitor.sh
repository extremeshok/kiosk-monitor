#!/usr/bin/env bash
# ======================================================================
# Coded by Adrian Jon Kriel :: admin@extremeshok.com
# ======================================================================
# kiosk-monitor.sh :: version 5.0.0
#======================================================================
# Monitors a Chromium or Firefox kiosk session on Raspberry Pi:
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
#   - Firefox/Firefox-ESR installed as /usr/bin/firefox when BROWSER=firefox
#======================================================================
# DEBUGGING:
#   • Enable verbose output by either:
#       export DEBUG=true          # environment variable
#       ./kiosk-watchdog.sh --debug
#======================================================================
# Usage:
#   ./kiosk-monitor.sh --install
#   ./kiosk-monitor.sh --help
#======================================================================
# Configuration:
#   Override behaviour via /etc/kiosk-monitor/kiosk-monitor.conf (shell-style) or environment vars.
#
# ======================================================================

# requires:
#   apt install x11-apps grim fbset wayland-utils

set -Eeuo pipefail

SCRIPT_VERSION="5.0.0"

CONFIG_DIR_DEFAULT="/etc/kiosk-monitor"
CONFIG_DIR_ENV="${CONFIG_DIR:-}"
CONFIG_FILE_ENV="${CONFIG_FILE:-}"

if [ -n "$CONFIG_FILE_ENV" ]; then
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
CHROME_LAUNCH_DELAY="${CHROME_LAUNCH_DELAY:-3}"
CHROME_READY_DELAY="${CHROME_READY_DELAY:-2}"
PROFILE_TMPFS="${PROFILE_TMPFS:-false}"
PROFILE_TMPFS_PATH="${PROFILE_TMPFS_PATH:-/dev/shm/kiosk-monitor}"
PROFILE_SYNC_BACK="${PROFILE_SYNC_BACK:-false}"
PROFILE_ARCHIVE="${PROFILE_ARCHIVE:-}"
PROFILE_TMPFS_PURGE="${PROFILE_TMPFS_PURGE:-false}"
PROFILE_SYNC_INTERVAL="${PROFILE_SYNC_INTERVAL:-0}"
PREWARM_ENABLED="${PREWARM_ENABLED:-true}"
PREWARM_PATHS="${PREWARM_PATHS:-}"
PREWARM_MAX_FILES="${PREWARM_MAX_FILES:-512}"
PREWARM_SLICE_SIZE="${PREWARM_SLICE_SIZE:-262144}"
SESSION_READY_DELAY="${SESSION_READY_DELAY:-0}"
SESSION_READY_CMD="${SESSION_READY_CMD:-}"
SESSION_READY_TIMEOUT="${SESSION_READY_TIMEOUT:-0}"
BROWSER="${BROWSER:-chromium}"
BROWSER=$(printf '%s' "$BROWSER" | tr '[:upper:]' '[:lower:]')

PREWARM_COMPLETED=false
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
  firefox|firefox-esr|ff)
    BROWSER_FLAVOR="firefox"
    BROWSER_LABEL="Firefox"
    if [ -n "${FIREFOX_BIN:-}" ]; then
      CHROME="$FIREFOX_BIN"
    elif command -v firefox >/dev/null 2>&1; then
      CHROME="$(command -v firefox)"
    elif command -v firefox-esr >/dev/null 2>&1; then
      CHROME="$(command -v firefox-esr)"
    else
      CHROME="/usr/bin/firefox"
    fi
    ;;
  *)
    echo "Unsupported BROWSER value: $BROWSER" >&2
    echo "Set BROWSER to 'chromium' or 'firefox'." >&2
    exit 1
    ;;
esac

ACTION="run"
case "${1:-}" in
  --install|--remove|--update)
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

run_low_priority() {
  if command -v ionice >/dev/null 2>&1; then
    ionice -c3 nice -n 15 "$@" >/dev/null 2>&1 || nice -n 15 "$@" >/dev/null 2>&1 || "$@" >/dev/null 2>&1
  else
    nice -n 15 "$@" >/dev/null 2>&1 || "$@" >/dev/null 2>&1
  fi
}

prewarm_file_chunk() {
  local file=$1
  local slice=$2
  [ -f "$file" ] || return 0
  if command -v dd >/dev/null 2>&1; then
    run_low_priority dd if="$file" of=/dev/null bs="$slice" count=1 status=none
  else
    run_low_priority head -c "$slice" "$file"
  fi
}

warm_path() {
  local target=$1
  local slice=$2
  local limit=$3
  [ -n "$target" ] || return 0
  if [ -f "$target" ]; then
    prewarm_file_chunk "$target" "$slice"
    return
  fi
  if [ -d "$target" ]; then
    local count=0
    while IFS= read -r -d '' file; do
      prewarm_file_chunk "$file" "$slice"
      count=$((count + 1))
      if [ "$count" -ge "$limit" ]; then
        break
      fi
    done < <(find "$target" -type f -size -10M -print0 2>/dev/null || true)
  fi
}

prewarm_browser_artifacts() {
  if [ "$PREWARM_ENABLED" != "true" ] || [ "$PREWARM_COMPLETED" = "true" ]; then
    return
  fi

  local slice="$PREWARM_SLICE_SIZE"
  if ! [[ "$slice" =~ ^[0-9]+$ ]]; then
    slice=262144
  fi
  local limit="$PREWARM_MAX_FILES"
  if ! [[ "$limit" =~ ^[0-9]+$ ]] || [ "$limit" -le 0 ]; then
    limit=512
  fi

  debug "Pre-warming $BROWSER_LABEL artifacts (slice=${slice}B, max_files=$limit)"
  warm_path "$CHROME" "$slice" "$limit"
  warm_path "$PROFILE_ROOT" "$slice" "$limit"

  local -a extras=()
  extras+=( "$(dirname "$CHROME")" )
  if [ "$BROWSER_FLAVOR" = "chromium" ]; then
    extras+=( /usr/lib/chromium-browser /usr/lib/chromium /opt/chromium )
  else
    extras+=( /usr/lib/firefox /usr/lib/firefox-esr /opt/firefox )
  fi
  if [ -n "$PREWARM_PATHS" ]; then
    IFS=':' read -r -a custom_paths <<< "$PREWARM_PATHS"
    extras+=( "${custom_paths[@]}" )
  fi

  local -A seen=()
  for extra in "${extras[@]}"; do
    [ -n "$extra" ] || continue
    local resolved
    resolved=$(readlink -f "$extra" 2>/dev/null || printf '%s' "$extra")
    [ -e "$resolved" ] || continue
    if [ "${seen[$resolved]+isset}" ]; then
      continue
    fi
    seen[$resolved]=1
    warm_path "$resolved" "$slice" "$limit"
  done

  PREWARM_COMPLETED=true
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

trim_firefox_cache() {
  local base="$PROFILE_DIR"
  rm -rf \
    "$base/cache2" \
    "$base/startupCache" \
    "$base/OfflineCache" \
    "$base/shader-cache" \
    "$base/Crash Reports" 2>/dev/null || true
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
  kiosk-monitor.sh --help | --version

Environment overrides:
  BASE_URL      Source for updates (default: project GitHub raw)
  INSTALL_DIR   Destination for the script (default: /usr/local/bin)
  SERVICE_PATH  systemd unit path (default: /etc/systemd/system/kiosk-monitor.service)
  CONFIG_DIR    Directory for config files (default: /etc/kiosk-monitor)
  CONFIG_FILE   Main config file path (default: /etc/kiosk-monitor/kiosk-monitor.conf)
  LOCK_FILE     Flock lock location (default: /var/lock/kiosk-monitor.lock)

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
    echo 'BROWSER="chromium"   # set to "firefox" to use Mozilla Firefox'
    echo '# CHROMIUM_BIN="/usr/bin/chromium-browser"'
    echo '# FIREFOX_BIN="/usr/bin/firefox"'
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

  local url_override=""
  local gui_override=""
  local browser_override=""
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

  mkdir -p "$INSTALL_DIR"
  download_component "kiosk-monitor.sh" "$INSTALL_DIR/kiosk-monitor.sh" 755
  download_component "kiosk-monitor.service" "$SERVICE_PATH" 644
  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_DIR/kiosk-monitor.conf.sample" ]; then
    download_component "config/kiosk-monitor.conf.sample" "$CONFIG_DIR/kiosk-monitor.conf.sample" 644
  fi
  if [ -f "$LEGACY_ENV_FILE" ] && [ ! -f "$CONFIG_FILE" ] && [ "$LEGACY_ENV_FILE" != "$CONFIG_FILE" ]; then
    mv "$LEGACY_ENV_FILE" "$CONFIG_FILE"
  fi
  ensure_config_file "$url_override" "$gui_override" "$browser_override"

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

  local browser_override=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base-url)
        shift
        BASE_URL="${1:-}"
        [ -n "$BASE_URL" ] || { echo 'Error: --base-url needs a value' >&2; exit 1; }
        ;;
      --browser)
        shift
        browser_override="${1:-}"
        [ -n "$browser_override" ] || { echo 'Error: --browser needs a value' >&2; exit 1; }
        browser_override=$(printf '%s' "$browser_override" | tr '[:upper:]' '[:lower:]')
        ;;
      *)
        printf 'Error: unknown update option %s\n' "$1" >&2
        usage
        exit 1
        ;;
    esac
    shift
  done

  mkdir -p "$INSTALL_DIR"
  mkdir -p "$CONFIG_DIR"
  local was_active="no"
  if systemctl is-active --quiet kiosk-monitor.service; then
    was_active="yes"
  fi

  download_component "kiosk-monitor.sh" "$INSTALL_DIR/kiosk-monitor.sh" 755
  download_component "kiosk-monitor.service" "$SERVICE_PATH" 644
  download_component "config/kiosk-monitor.conf.sample" "$CONFIG_DIR/kiosk-monitor.conf.sample" 644
  if [ -f "$LEGACY_ENV_FILE" ] && [ ! -f "$CONFIG_FILE" ] && [ "$LEGACY_ENV_FILE" != "$CONFIG_FILE" ]; then
    mv "$LEGACY_ENV_FILE" "$CONFIG_FILE"
  fi
  if [ -n "$browser_override" ]; then
    ensure_config_file "" "" "$browser_override"
  fi

  systemctl daemon-reload
  if [ "$was_active" = "yes" ]; then
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
LOG="${LOG:-/dev/shm/kiosk.log}"
mkdir -p "$(dirname "$LOG")" || true
: > "$LOG"   # truncate existing log each start
# Duplicate all stdout/stderr to both console and logfile
exec > >(tee -a "$LOG") 2>&1
need_cmd curl
need_cmd flock
mkdir -p "$(dirname "$LOCK_FILE")"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  echo "Another kiosk-monitor instance is already running (lock $LOCK_FILE)." >&2
  exit 0
fi

if [ "$DEBUG" = "true" ]; then
  set -x
fi

# Enable debug logging if DEBUG=true
debug() {
  # Print debug messages to stderr so they aren’t captured in $(...)
  if [ "$DEBUG" = "true" ]; then
    printf 'DEBUG: %s\n' "$*" >&2
  fi
}

# Run a command as the GUI user with proper env; if already that user, run directly
as_gui() {
  if [ "$(id -u)" -eq "${GUI_UID:-999999}" ] 2>/dev/null; then
    "$@"
  else
    sudo -n -u "$GUI_USER" env XDG_RUNTIME_DIR="/run/user/$GUI_UID" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" DISPLAY="${DISPLAY:-}" "$@"
  fi
}

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
    echo "No valid GUI user detected (not in a graphical session). Set GUI_USER= in the service env." >&2
    exit 1
  fi
fi
GUI_UID=$(id -u "$GUI_USER")
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${GUI_UID}}"

PROFILE_PERSIST_ROOT="${PROFILE_ROOT:-/home/${GUI_USER}/.local/share/kiosk-monitor}"
PROFILE_RUNTIME_ROOT="$PROFILE_PERSIST_ROOT"

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

PROFILE_SYNC_PID=""

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
    local pattern
    case "$BROWSER_FLAVOR" in
      chromium)
        pattern="${CHROMIUM_PGREP_PATTERN:-}"
        ;;
      firefox)
        pattern="--profile=${PROFILE_ROOT}"
        ;;
      *)
        pattern="$(basename "$CHROME")"
        ;;
    esac
    if [ -z "$pattern" ]; then
      pattern="--type=browser"
    fi
    mapfile -t main_pids < <(pgrep -u "$GUI_USER" -f "$pattern" 2>/dev/null || true)
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

  case "$BROWSER_FLAVOR" in
    chromium)
      if [ -n "${CHROMIUM_PGREP_PATTERN:-}" ]; then
        mapfile -t dupes < <(pgrep -u "$GUI_USER" -f "${CHROMIUM_PGREP_PATTERN}" 2>/dev/null || true)
      else
        mapfile -t dupes < <(pgrep -u "$GUI_USER" -f "--type=browser" 2>/dev/null || true)
      fi
      ;;
    firefox)
      mapfile -t dupes < <(pgrep -u "$GUI_USER" -f "--profile=${PROFILE_ROOT}" 2>/dev/null || true)
      ;;
    *)
      mapfile -t dupes < <(pgrep -u "$GUI_USER" -f "$(basename "$CHROME")" 2>/dev/null || true)
      ;;
  esac
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
  local keyword=""

  case "$BROWSER_FLAVOR" in
    chromium)
      keyword="chromium"
      ;;
    firefox)
      keyword="firefox"
      ;;
    *)
      return
      ;;
  esac

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

prepare_profile_runtime
start_profile_sync_timer

PROFILE_ROOT="$PROFILE_RUNTIME_ROOT"
if [ "$BROWSER_FLAVOR" = "chromium" ]; then
  profile_regex=$(regex_escape "$PROFILE_ROOT")
  CHROMIUM_PGREP_PATTERN="--user-data-dir=$profile_regex"
  PROFILE_DIR="$PROFILE_ROOT/Default"
  PROFILE_PREFS="$PROFILE_DIR/Preferences"
else
  CHROMIUM_PGREP_PATTERN=""
  PROFILE_DIR="$PROFILE_ROOT"
  PROFILE_PREFS="$PROFILE_DIR/prefs.js"
fi
mkdir -p "$PROFILE_DIR"

BROWSER_PID=""                       # will hold the main browser PID
SKIP_HEALTH_LOOP=false

# ——— Environment ———
# DISPLAY: prefer env; else infer from loginctl; else :0
if [ -z "${DISPLAY:-}" ]; then
  if command -v loginctl >/dev/null 2>&1; then
    GUI_DISPLAY=$(loginctl show-user "$GUI_USER" -p Display --value 2>/dev/null || true)
  fi
  export DISPLAY=":${GUI_DISPLAY:-0}"
fi
# XAUTHORITY may be needed for X11 fallback; harmless on Wayland
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


# ------------------------------------------------------------
# Display‑resolution detection
#   • On Wayland: use wayland-info logical_* entries (two quick greps)
#   • Else:       fall back to fbset geometry
# ------------------------------------------------------------
if [ "$BACKEND" = "wayland" ] && command -v wayland-info >/dev/null 2>&1; then
    max_try=5
    try=1
    width=""; height=""
    while [ $try -le $max_try ]; do
      width=$(as_gui wayland-info --outputs | grep -m1 'logical_width:' | sed -E 's/.*logical_width:[[:blank:]]*([0-9]+).*/\1/')
      height=$(as_gui wayland-info --outputs | grep -m1 'logical_height:' | sed -E 's/.*logical_height:[[:blank:]]*([0-9]+).*/\1/')
      if [ -n "$width" ] && [ -n "$height" ]; then
        break
      fi
      echo "wayland-info did not yield logical_width/height (attempt $try/$max_try) — retrying in 1 s" >&2
      sleep 1
      try=$((try + 1))
    done

    if [ -z "$width" ] || [ -z "$height" ]; then
        echo "ERROR: Could not determine resolution via wayland-info after $max_try attempts" >&2
        exit 1
    fi

    res="${width}x${height}"
    # Obtain first Wayland output name (may be empty on some compositors)
    OUTPUT_NAME=$(as_gui wayland-info --outputs | awk '/^[[:space:]]*name:[[:space:]]*/ { gsub(/^'\''|'\''$/, "", $2); print $2; exit }')
    if [ -n "$OUTPUT_NAME" ]; then
      GRIM_OUT_OPT=( -o "$OUTPUT_NAME" )
      debug "Primary Wayland output: $OUTPUT_NAME"
    else
      GRIM_OUT_OPT=()
      debug "WARNING: Could not detect primary Wayland output; grim will capture all outputs"
    fi

elif command -v fbset >/dev/null 2>&1; then
    res=$(fbset -s | awk '/geometry/ {print $2"x"$3}')
    debug "Resolution detected via fbset: $res"

else
    printf "ERROR: Cannot determine resolution (install wayland-utils or fbset)\n" >&2
    exit 1
fi

screen_w=${res%x*}; screen_h=${res#*x}
printf 'Detected display: %dx%d\n' "$screen_w" "$screen_h"

# ——— Configurable watchdog parameters ———
HEALTH_INTERVAL=30        # seconds between probes
HEALTH_RETRIES=6          # consecutive failures before restart
RESTART_WINDOW=600        # seconds to look back for storm protection
MAX_RESTARTS=10           # max restarts allowed within the window
STALL_RETRIES=3          # unchanged screen cycles before restart
SCREEN_DELAY=120           # seconds to wait before starting visual‑freeze checks

URL="${URL:-$DEFAULT_URL}"
case "$BROWSER_FLAVOR" in
  chromium)
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
      --app="$URL"
    )
    ;;
  firefox)
    FLAGS=(
      --kiosk
      --private-window
      --no-remote
      --profile="$PROFILE_ROOT"
      "$URL"
    )
    ;;
esac

# ——— Prefs patcher ———
patch_prefs() {
  if [ "$BROWSER_FLAVOR" = "chromium" ]; then
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
if target_url:
    browser['last_opened_urls'] = [target_url]
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
    return
  fi

  # Firefox profile tuning
  mkdir -p "$PROFILE_DIR"
  local user_js="$PROFILE_DIR/user.js"
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
user_pref("app.update.auto", false);
user_pref("app.update.enabled", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.cache.disk.enable", false);
user_pref("browser.fullscreen.autohide", false);
user_pref("browser.fullscreen.animate", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage", "about:blank");
user_pref("browser.startup.page", 0);
user_pref("browser.tabs.warnOnClose", false);
user_pref("browser.tabs.warnOnOpen", false);
user_pref("browser.warnOnQuitShortcut", false);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.sessionstore.max_resumed_crashes", 0);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("dom.disable_open_during_load", false);
user_pref("media.autoplay.default", 0);
user_pref("media.ffmpeg.vaapi.enabled", true);
user_pref("media.hardware-video-decoding.enabled", true);
user_pref("media.gmp-gmpopenh264.enabled", true);
user_pref("media.gmp-manager.updateEnabled", true);
user_pref("sanitizer.promptOnSanitize", false);
user_pref("signon.rememberSignons", false);
user_pref("toolkit.startup.max_resumed_crashes", 0);
EOF
  install -m 0644 "$tmp" "$user_js"
  rm -f "$tmp"

  rm -f "$PROFILE_DIR"/sessionstore*.jsonlz4 2>/dev/null || true
  rm -f "$PROFILE_DIR"/sessionCheckpoints*.json 2>/dev/null || true
  rm -rf "$PROFILE_DIR"/sessionstore-backups 2>/dev/null || true
  rm -rf "$PROFILE_DIR"/crashes 2>/dev/null || true
  rm -rf "$PROFILE_DIR"/"Crash Reports" 2>/dev/null || true

  trim_firefox_cache
  chown -R "$GUI_USER":"$GUI_USER" "$PROFILE_ROOT"
}

# ——— Health‑check helpers ———
health_check() {
  CODE=$(curl -s --head --fail --connect-timeout 3 --max-time 5 -o /dev/null -w "%{http_code}" "$URL" || echo 000)
  debug "health_check HTTP code=$CODE"
  [ "$CODE" -ge 200 ] && [ "$CODE" -lt 400 ]
}

# --- Screen-hash helper (detect visual freeze via half-screen) ---
capture_hash() {
  if [ "$BACKEND" = "wayland" ]; then
    debug "Capturing full-screen sample on Wayland"
    data=$(as_gui grim "${GRIM_OUT_OPT[@]}" -t ppm - - | head -c 65536 | base64 -w0)
    debug "Full-screen sample base64 length=${#data}"
  else
    # fallback: sample first 64KiB of full-screen dump to save CPU
    debug "Fallback command: xwd -silent -root -display \"$DISPLAY\" | head -c 65536"
    data=$(as_gui xwd -silent -root -display "$DISPLAY" | head -c 65536 | base64 -w0)
    debug "Captured base64 length=${#data}"
  fi
  # Return a 32‑bit checksum of the captured PPM/XWD bytes
  checksum=$(printf '%s' "$data" | cksum | awk '{print $1}')
  debug "Computed hash: $checksum"
  printf '%s\n' "$checksum"
}

# Keep track of restart bursts so we don’t loop forever
record_restart() {
  stop_browser
  now=$(date +%s)
  debug "Recording restart at $now (window size=${#restart_times[@]})"
  restart_times=( "${restart_times[@]}" "$now" )
  # drop timestamps older than RESTART_WINDOW
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

# ——— Browser control ———
start_browser() {
  need_cmd "$CHROME"
  maybe_defer_launch
  prewarm_browser_artifacts
  stop_other_browser_sessions
  patch_prefs
  EXTRA_FLAGS=()
  if [ "$BROWSER_FLAVOR" = "chromium" ] && [ "$BACKEND" = "wayland" ]; then
    EXTRA_FLAGS+=( --enable-features=UseOzonePlatform --ozone-platform=wayland )
  fi
  debug "Starting $BROWSER_LABEL with flags: ${FLAGS[*]} ${EXTRA_FLAGS[*]}"
  local launcher=("$CHROME")
  if [ "$BROWSER_FLAVOR" = "firefox" ] && [ "$BACKEND" = "wayland" ]; then
    launcher=(env MOZ_ENABLE_WAYLAND=1 "$CHROME")
  fi
  as_gui "${launcher[@]}" "${EXTRA_FLAGS[@]}" "${FLAGS[@]}" > /dev/null 2>&1 &
  debug "Launched $BROWSER_LABEL…"
  sleep "$CHROME_LAUNCH_DELAY"

  LAUNCHER_PID=$!
  # Wait briefly for the browser to spin up the real process tree
  sleep "$CHROME_READY_DELAY"
  if [ "$BROWSER_FLAVOR" = "chromium" ]; then
    if [ -n "${CHROMIUM_PGREP_PATTERN:-}" ]; then
      BROWSER_PID=$(pgrep -u "$GUI_USER" -o -f "${CHROMIUM_PGREP_PATTERN}" || true)
    else
      BROWSER_PID=$(pgrep -u "$GUI_USER" -o -f "--type=browser" || true)
    fi
  else
    BROWSER_PID=$(pgrep -u "$GUI_USER" -o -f "--profile=${PROFILE_ROOT}" || pgrep -u "$GUI_USER" -o "$(basename "$CHROME")" || true)
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
    wait "$BROWSER_PID" || true
    BROWSER_PID=""
  else
    BROWSER_PID=""
  fi
}

# Ensure we exit cleanly when systemd (or a user) sends INT/TERM
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

# ——— Startup/Shutdown trap ———
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

trap cleanup EXIT
trap handle_shutdown_signal INT TERM
printf '==== START %s at %s ====\n' "$0" "$(date -Is)"

# ——— Initial browser detection and launch ———
if [ "$BROWSER_FLAVOR" = "chromium" ]; then
  if [ -n "${CHROMIUM_PGREP_PATTERN:-}" ]; then
    existing_pid=$(pgrep -u "$GUI_USER" -o -f "${CHROMIUM_PGREP_PATTERN}" || true)
  else
    existing_pid=$(pgrep -u "$GUI_USER" -o -f "--type=browser" || true)
  fi
else
  existing_pid=$(pgrep -u "$GUI_USER" -o -f "--profile=${PROFILE_ROOT}" || pgrep -u "$GUI_USER" -o "$(basename "$CHROME")" || true)
fi
if [ -n "$existing_pid" ]; then
  BROWSER_PID=$existing_pid
  stop_other_browser_sessions "$BROWSER_PID"
  proc_age=$(ps -p "$BROWSER_PID" -o etimes= --no-headers | tr -d ' ')
  printf '%s already running (PID %s), skipping initial launch\n' "$BROWSER_LABEL" "$BROWSER_PID"
  # Ensure server is responding at least once
  if ! health_check; then
    echo "Initial health check failed, waiting for server... ($(date))"
    until health_check; do
      echo "  still down at $(date)"
      sleep 1
    done
  fi
  # Seed last_hash so display‐stall checking begins immediately
  last_hash=$(capture_hash)
  stall_count=0
  SKIP_HEALTH_LOOP=true
else
  if [ "$WAIT_FOR_URL" = "true" ]; then
    printf 'Waiting for %s …\n' "$URL"
    until health_check; do
      echo "  still down at $(date)"
      sleep 1
    done
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
CLEAN_RESET=600   # seconds of healthy run to reset restart history

while true; do

  debug "Watchdog loop iteration: ${BROWSER_LABEL}_PID=$BROWSER_PID, consecutive_failures=$consecutive_failures, stall_count=$stall_count"

  # 1) Did the browser disappear?
  if ! kill -0 "$BROWSER_PID" 2>/dev/null; then
    echo "$BROWSER_LABEL main PID $BROWSER_PID vanished — restarting…"
    record_restart
    continue
  fi

  active_pattern=""
  if [ "$BROWSER_FLAVOR" = "chromium" ]; then
    if [ -n "${CHROMIUM_PGREP_PATTERN:-}" ]; then
      active_pattern="$CHROMIUM_PGREP_PATTERN"
    else
      active_pattern="--type=browser"
    fi
  else
    active_pattern="--profile=${PROFILE_ROOT}"
  fi
  mapfile -t active_browsers < <(pgrep -u "$GUI_USER" -f "$active_pattern" 2>/dev/null || true)
  if [ "${#active_browsers[@]}" -gt 1 ]; then
    echo "Detected multiple $BROWSER_LABEL processes — pruning extras"
    stop_other_browser_sessions "$BROWSER_PID"
    if [ "$BROWSER_FLAVOR" = "chromium" ]; then
      if [ -n "${CHROMIUM_PGREP_PATTERN:-}" ]; then
        BROWSER_PID=$(pgrep -u "$GUI_USER" -o -f "${CHROMIUM_PGREP_PATTERN}" || true)
      else
        BROWSER_PID=$(pgrep -u "$GUI_USER" -o -f "--type=browser" || true)
      fi
    else
      BROWSER_PID=$(pgrep -u "$GUI_USER" -o -f "--profile=${PROFILE_ROOT}" || pgrep -u "$GUI_USER" -o "$(basename "$CHROME")" || true)
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
