#!/usr/bin/env bash
# ======================================================================
# Coded by Adrian Jon Kriel :: admin@extremeshok.com
# ======================================================================
# kiosk-monitor.sh :: version 6.4.0
# ======================================================================
# Kiosk watchdog for Raspberry Pi OS trixie 64-bit (or newer Debian/RPi).
# Supports Chromium fullscreen kiosk and VLC fullscreen video playback,
# optionally on two displays at once. Monitors each instance for hangs /
# frozen frames and restarts only the affected instance.
#
# Target stack (minimum):
#   - Raspberry Pi OS trixie 64-bit Desktop
#   - Wayland (labwc compositor)
#   - systemd
#   - Chromium, VLC, grim, wlr-randr, curl, python3 (all in the default image)
# ======================================================================
# Usage:
#   sudo kiosk-monitor.sh --install       [options]
#   sudo kiosk-monitor.sh --update        [options]
#   sudo kiosk-monitor.sh --remove        [--purge]
#   sudo kiosk-monitor.sh --reconfig
#        kiosk-monitor.sh --status
#        kiosk-monitor.sh --help | --version
# ======================================================================

set -Eeuo pipefail

SCRIPT_VERSION="6.4.0"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# ------------------------------------------------------------------
# CLI pre-pass: --config only (so --config works for every action)
# ------------------------------------------------------------------
CONFIG_FILE_OVERRIDE=""
CONFIG_ARGV=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config=*)
      CONFIG_FILE_OVERRIDE="${1#--config=}"
      shift
      ;;
    --config)
      shift
      [ "$#" -gt 0 ] || { echo "Error: --config requires a path" >&2; exit 1; }
      CONFIG_FILE_OVERRIDE="$1"
      shift
      ;;
    --)
      CONFIG_ARGV+=( "$@" )
      break
      ;;
    *)
      CONFIG_ARGV+=( "$1" )
      shift
      ;;
  esac
done
if [ "${#CONFIG_ARGV[@]}" -gt 0 ]; then
  set -- "${CONFIG_ARGV[@]}"
else
  set --
fi

CONFIG_DIR_DEFAULT="/etc/kiosk-monitor"
CONFIG_DIR_ENV="${CONFIG_DIR:-}"
CONFIG_FILE_ENV="${CONFIG_FILE:-}"

if [ -n "$CONFIG_FILE_OVERRIDE" ]; then
  CONFIG_FILE="$CONFIG_FILE_OVERRIDE"
  CONFIG_DIR=$(dirname "$CONFIG_FILE")
elif [ -n "$CONFIG_FILE_ENV" ]; then
  CONFIG_FILE="$CONFIG_FILE_ENV"
  CONFIG_DIR="${CONFIG_DIR_ENV:-$(dirname "$CONFIG_FILE")}"
else
  CONFIG_DIR="${CONFIG_DIR_ENV:-$CONFIG_DIR_DEFAULT}"
  CONFIG_FILE="$CONFIG_DIR/kiosk-monitor.conf"
fi
ENV_FILE="${ENV_FILE:-$CONFIG_FILE}"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

# ------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------
DEFAULT_URL="http://192.168.3.222:30059/?Birdseye"
# HEAD resolves to the repo's default branch (works for both main and master).
DEFAULT_BASE_URL="https://raw.githubusercontent.com/extremeshok/kiosk-monitor/HEAD"
BASE_URL="${BASE_URL:-$DEFAULT_BASE_URL}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
SERVICE_PATH="${SERVICE_PATH:-/etc/systemd/system/kiosk-monitor.service}"
LOCK_FILE="${LOCK_FILE:-/var/lock/kiosk-monitor.lock}"

# Legacy compatibility: accept BROWSER as a MODE alias.
if [ -z "${MODE:-}" ] && [ -n "${BROWSER:-}" ]; then
  MODE="$BROWSER"
fi
MODE="${MODE:-chrome}"
MODE2="${MODE2:-}"
URL="${URL:-$DEFAULT_URL}"
URL2="${URL2:-}"
OUTPUT="${OUTPUT:-}"
OUTPUT2="${OUTPUT2:-}"

# Per-instance display forcing (applied via wlr-randr before launch).
# FORCE_RESOLUTION: "" | "WxH" | "WxH@RATE" (e.g. "1920x1080@60")
# FORCE_ROTATION:   "" | "normal" | "90" | "180" | "270"
#                   | "flipped" | "flipped-90" | "flipped-180" | "flipped-270"
FORCE_RESOLUTION="${FORCE_RESOLUTION:-}"
FORCE_RESOLUTION_2="${FORCE_RESOLUTION_2:-}"
FORCE_ROTATION="${FORCE_ROTATION:-}"
FORCE_ROTATION_2="${FORCE_ROTATION_2:-}"

# Chromium-specific
CHROMIUM_BIN="${CHROMIUM_BIN:-}"
# Frigate Birdseye helper — left empty triggers smart defaults when the URL
# looks like a Frigate Birdseye view (see apply_frigate_smart_defaults).
# Legacy BIRDSEYE_* names are still honoured.
FRIGATE_BIRDSEYE_AUTO_FILL="${FRIGATE_BIRDSEYE_AUTO_FILL:-${BIRDSEYE_AUTO_FILL:-}}"
FRIGATE_BIRDSEYE_MATCH_PATTERN="${FRIGATE_BIRDSEYE_MATCH_PATTERN:-${BIRDSEYE_MATCH_PATTERN:-}}"
FRIGATE_BIRDSEYE_EXTENSION_DIR="${FRIGATE_BIRDSEYE_EXTENSION_DIR:-${BIRDSEYE_EXTENSION_DIR:-}}"
# Fixed pixel dimensions for the birdseye grid/canvas. Left empty = auto,
# derived from the instance's output resolution minus FRIGATE_BIRDSEYE_MARGIN
# on each axis. Explicit integers override that and pin the size.
FRIGATE_BIRDSEYE_WIDTH="${FRIGATE_BIRDSEYE_WIDTH:-}"
FRIGATE_BIRDSEYE_HEIGHT="${FRIGATE_BIRDSEYE_HEIGHT:-}"
FRIGATE_BIRDSEYE_MARGIN="${FRIGATE_BIRDSEYE_MARGIN:-80}"
# Frigate UI theming — applied via content script on matching pages.
# Values: "" (auto-default for Frigate URLs), "None" (explicit skip),
# "Light"/"Dark" or one of the known theme names.
FRIGATE_DARK_MODE="${FRIGATE_DARK_MODE:-}"
FRIGATE_THEME="${FRIGATE_THEME:-}"
FRIGATE_THEME_STORAGE_KEY="${FRIGATE_THEME_STORAGE_KEY:-frigate-ui-theme}"
FRIGATE_COLOR_STORAGE_KEY="${FRIGATE_COLOR_STORAGE_KEY:-frigate-ui-color-scheme}"
DEVTOOLS_AUTO_OPEN="${DEVTOOLS_AUTO_OPEN:-false}"
DEVTOOLS_REMOTE_PORT="${DEVTOOLS_REMOTE_PORT:-}"

# VLC-specific
VLC_BIN="${VLC_BIN:-}"
VLC_LOOP="${VLC_LOOP:-true}"
VLC_NO_AUDIO="${VLC_NO_AUDIO:-false}"
VLC_EXTRA_ARGS="${VLC_EXTRA_ARGS:-}"
VLC_NETWORK_CACHING="${VLC_NETWORK_CACHING:-}"

# Profiles / caching
PROFILE_ROOT="${PROFILE_ROOT:-}"
PROFILE_TMPFS="${PROFILE_TMPFS:-false}"
PROFILE_TMPFS_PATH="${PROFILE_TMPFS_PATH:-/dev/shm/kiosk-monitor}"
PROFILE_SYNC_BACK="${PROFILE_SYNC_BACK:-false}"
PROFILE_TMPFS_PURGE="${PROFILE_TMPFS_PURGE:-false}"
PROFILE_ARCHIVE="${PROFILE_ARCHIVE:-}"
PROFILE_SYNC_INTERVAL="${PROFILE_SYNC_INTERVAL:-0}"

# Prewarm
PREWARM_ENABLED="${PREWARM_ENABLED:-true}"
PREWARM_PATHS="${PREWARM_PATHS:-}"
PREWARM_MAX_FILES="${PREWARM_MAX_FILES:-512}"
PREWARM_SLICE_SIZE="${PREWARM_SLICE_SIZE:-262144}"

# Session / readiness
SESSION_READY_DELAY="${SESSION_READY_DELAY:-0}"
SESSION_READY_CMD="${SESSION_READY_CMD:-}"
SESSION_READY_TIMEOUT="${SESSION_READY_TIMEOUT:-0}"
GUI_SESSION_WAIT_TIMEOUT="${GUI_SESSION_WAIT_TIMEOUT:-300}"
WAYLAND_READY_TIMEOUT="${WAYLAND_READY_TIMEOUT:-300}"
WAIT_FOR_URL="${WAIT_FOR_URL:-true}"
WAIT_FOR_URL_TIMEOUT="${WAIT_FOR_URL_TIMEOUT:-0}"
MIN_UPTIME_BEFORE_START="${MIN_UPTIME_BEFORE_START:-60}"
CHROME_LAUNCH_DELAY="${CHROME_LAUNCH_DELAY:-3}"
CHROME_READY_DELAY="${CHROME_READY_DELAY:-2}"
VLC_LAUNCH_DELAY="${VLC_LAUNCH_DELAY:-3}"

# Freeze / health tuning
SCREEN_DELAY="${SCREEN_DELAY:-120}"
SCREEN_SAMPLE_BYTES="${SCREEN_SAMPLE_BYTES:-524288}"
SCREEN_SAMPLE_MODE="${SCREEN_SAMPLE_MODE:-sample}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-30}"
HEALTH_CONNECT_TIMEOUT="${HEALTH_CONNECT_TIMEOUT:-3}"
HEALTH_TOTAL_TIMEOUT="${HEALTH_TOTAL_TIMEOUT:-8}"
STALL_RETRIES="${STALL_RETRIES:-3}"
HEALTH_RETRIES="${HEALTH_RETRIES:-6}"
RESTART_WINDOW="${RESTART_WINDOW:-600}"
MAX_RESTARTS="${MAX_RESTARTS:-10}"
CLEAN_RESET="${CLEAN_RESET:-600}"
VLC_STALL_RETRIES="${VLC_STALL_RETRIES:-6}"

# Log rotation (in-process, copy-truncate so the tee fd stays valid)
LOG_MAX_BYTES="${LOG_MAX_BYTES:-2097152}"     # 2 MiB
LOG_ROTATE_KEEP="${LOG_ROTATE_KEEP:-1}"       # 0 disables the .1 copy

# --- Frigate URL detection + smart defaults ---------------------------
is_frigate_birdseye_url() {
  local url=$1 lc
  [ -n "$url" ] || return 1
  lc=$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')
  # Matches query strings like "?birdseye", "?birdseye=...", "&birdseye", etc.
  case "$lc" in
    *\?birdseye|*\?birdseye=*|*\?birdseye\&*|*\&birdseye|*\&birdseye=*|*\&birdseye\&*)
      return 0 ;;
    *) return 1 ;;
  esac
}

apply_frigate_smart_defaults() {
  local is_frigate="no"
  if [ "${MODE:-}" = "chrome" ] || [ "${MODE:-}" = "chromium" ]; then
    is_frigate_birdseye_url "${URL:-}" && is_frigate="yes"
  fi
  if [ "$is_frigate" = "no" ] && { [ "${MODE2:-}" = "chrome" ] || [ "${MODE2:-}" = "chromium" ]; }; then
    is_frigate_birdseye_url "${URL2:-}" && is_frigate="yes"
  fi
  [ "$is_frigate" = "yes" ] || return 0
  # Fill in opinionated defaults only when the user left the value empty.
  [ -z "${FRIGATE_BIRDSEYE_AUTO_FILL:-}" ] && FRIGATE_BIRDSEYE_AUTO_FILL="true"
  [ -z "${FRIGATE_DARK_MODE:-}" ]          && FRIGATE_DARK_MODE="Dark"
  [ -z "${FRIGATE_THEME:-}" ]              && FRIGATE_THEME="High Contrast"
  return 0
}

apply_frigate_smart_defaults

# Ensure autofill has a concrete value once smart defaults have run.
FRIGATE_BIRDSEYE_AUTO_FILL="${FRIGATE_BIRDSEYE_AUTO_FILL:-false}"

# Normalize booleans/strings (lower-case)
for _var in MODE MODE2 VLC_LOOP VLC_NO_AUDIO PROFILE_TMPFS PROFILE_SYNC_BACK PROFILE_TMPFS_PURGE \
            PREWARM_ENABLED FRIGATE_BIRDSEYE_AUTO_FILL DEVTOOLS_AUTO_OPEN WAIT_FOR_URL; do
  val="${!_var}"
  val="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
  printf -v "$_var" '%s' "$val"
done
unset _var val

case "$MODE" in chromium|chrome) MODE="chrome" ;; esac
case "$MODE2" in chromium|chrome) MODE2="chrome" ;; esac

# Normalize FRIGATE_DARK_MODE: "Light"/"Dark" → lower; "None"/anything else → empty
case "$(printf '%s' "$FRIGATE_DARK_MODE" | tr '[:upper:]' '[:lower:]')" in
  light) FRIGATE_DARK_MODE="light" ;;
  dark)  FRIGATE_DARK_MODE="dark" ;;
  *)     FRIGATE_DARK_MODE="" ;;
esac

# Normalize FRIGATE_THEME to lowercase/dash (shadcn-style slug).
# "Default"/"None"/"" all mean "no override".
_theme_lc=$(printf '%s' "$FRIGATE_THEME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
case "$_theme_lc" in
  blue|green|nord|red|high-contrast) FRIGATE_THEME="$_theme_lc" ;;
  ""|default|none)                   FRIGATE_THEME="" ;;
  *)  echo "Warning: unrecognized FRIGATE_THEME='$FRIGATE_THEME' (passing through as-is)" >&2
      FRIGATE_THEME="$_theme_lc" ;;
esac
unset _theme_lc

if [ "$MODE" != "chrome" ] && [ "$MODE" != "vlc" ]; then
  echo "Error: unsupported MODE='$MODE' (expected chrome or vlc)" >&2
  exit 1
fi
if [ -n "$MODE2" ] && [ "$MODE2" != "chrome" ] && [ "$MODE2" != "vlc" ]; then
  echo "Error: unsupported MODE2='$MODE2' (expected chrome, vlc, or empty)" >&2
  exit 1
fi

case "$SCREEN_SAMPLE_MODE" in full|sample) ;; *) SCREEN_SAMPLE_MODE="sample" ;; esac
if ! [[ "$SCREEN_SAMPLE_BYTES" =~ ^[0-9]+$ ]] || [ "$SCREEN_SAMPLE_BYTES" -le 0 ]; then
  SCREEN_SAMPLE_BYTES=524288
fi

SHUTDOWN_REQUESTED=false
RELOAD_REQUESTED=false
DEFERRED_LAUNCH_DONE=false
PROFILE_SYNC_PID=""
declare -A OUTPUT_GEOMETRY=()
OUTPUTS_NAMES=()

# Per-instance state (associative arrays keyed by instance id 1/2)
declare -A INSTANCE_MODE=()
declare -A INSTANCE_URL=()
declare -A INSTANCE_OUTPUT=()
declare -A INSTANCE_PID=()
declare -A INSTANCE_LAST_HASH=()
declare -A INSTANCE_STALL_COUNT=()
declare -A INSTANCE_FAIL_COUNT=()
declare -A INSTANCE_LAST_GOOD=()
declare -A INSTANCE_RESTART_LOG=()
declare -A INSTANCE_PROFILE_DIR=()
declare -A INSTANCE_MATCH=()
declare -A INSTANCE_STALL_THRESHOLD=()
declare -A INSTANCE_PAUSED=()
declare -A INSTANCE_FORCE_RESOLUTION=()
declare -A INSTANCE_FORCE_ROTATION=()
declare -A INSTANCE_CLASS=()
INSTANCES=()

# ======================================================================
# Basic helpers
# ======================================================================
need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Error: required command %s not found in PATH\n' "$1" >&2
    exit 1
  fi
}

debug() {
  if [ "${DEBUG:-false}" = "true" ]; then
    printf 'DEBUG: %s\n' "$*" >&2
  fi
}

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
log_instance() { local id=$1; shift; log "[$id ${INSTANCE_MODE[$id]:-?}@${INSTANCE_OUTPUT[$id]:-auto}] $*"; }
debug_instance() { local id=$1; shift; debug "[$id ${INSTANCE_MODE[$id]:-?}@${INSTANCE_OUTPUT[$id]:-auto}] $*"; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    printf 'Error: %s requires root; re-run with sudo\n' "$SCRIPT_NAME" >&2
    exit 1
  fi
}

init_log_file() {
  local target=$1
  local dir
  dir=$(dirname "$target")
  mkdir -p "$dir" 2>/dev/null || return 1
  : > "$target" 2>/dev/null || { rm -f "$target" 2>/dev/null; : > "$target" 2>/dev/null || return 1; }
  return 0
}

rotate_log_if_needed() {
  local max="${LOG_MAX_BYTES:-2097152}"
  [[ "$max" =~ ^[0-9]+$ ]] || return 0
  [ "$max" -gt 0 ] || return 0
  [ -n "${LOG:-}" ] && [ -f "$LOG" ] || return 0
  local size
  size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  [ "$size" -gt "$max" ] || return 0
  local keep="${LOG_ROTATE_KEEP:-1}"
  # copy-truncate keeps the fd open on the tee process we spawned at startup
  if [ "$keep" -gt 0 ]; then
    cp -f "$LOG" "${LOG}.1" 2>/dev/null || true
  fi
  : > "$LOG" 2>/dev/null || true
  return 0
}

open_lock_file() {
  local requested=$1
  local uid="${EUID:-$(id -u)}"
  local -a candidates=()
  [ -n "$requested" ] && candidates+=( "$requested" )
  if [ "$uid" -ne 0 ]; then
    [ -n "${XDG_RUNTIME_DIR:-}" ] && candidates+=( "${XDG_RUNTIME_DIR%/}/kiosk-monitor.lock" )
    candidates+=( "/tmp/kiosk-monitor-${uid}.lock" )
  fi
  candidates+=( "/tmp/kiosk-monitor-${uid}.lock" )
  local target dir
  for target in "${candidates[@]}"; do
    [ -n "$target" ] || continue
    dir=$(dirname "$target")
    mkdir -p "$dir" 2>/dev/null || continue
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
  [ "$src" = "$dst" ] && return 0
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
  [ -f "$archive" ] || return 1
  need_cmd tar
  clear_directory "$dest"
  if ! tar -xaf "$archive" -C "$dest"; then
    echo "Failed to extract $archive" >&2
    return 1
  fi
  return 0
}

derive_match_pattern() {
  local raw=$1
  local fallback="http://*/*"
  [ -z "$raw" ] && { printf '%s\n' "$fallback"; return; }
  [[ "$raw" == *"://"* ]] || raw="http://$raw"
  local scheme="${raw%%://*}"
  local remainder="${raw#*://}"
  [ "$scheme" = "$raw" ] && { scheme="http"; remainder="$raw"; }
  local netloc="${remainder%%/*}"
  [ -z "$netloc" ] && netloc="*"
  printf '%s://%s/*\n' "$scheme" "$netloc"
}

ensure_minimum_uptime() {
  local min="${MIN_UPTIME_BEFORE_START:-0}"
  [[ "$min" =~ ^[0-9]+$ ]] && [ "$min" -gt 0 ] || return 0
  local elapsed=0
  [ -r /proc/uptime ] && elapsed=$(awk '{printf "%d\n",$1}' /proc/uptime 2>/dev/null || echo 0)
  [ "$elapsed" -ge "$min" ] && return 0
  local wait=$((min - elapsed))
  [ "$wait" -le 0 ] && wait=60
  log "System uptime ${elapsed}s < ${min}s — sleeping ${wait}s before kiosk start."
  sleep "$wait"
}

# ======================================================================
# Default desktop user detection
# ======================================================================
parse_autologin_conf() {
  local conf="/etc/systemd/system/getty@tty1.service.d/autologin.conf"
  [ -f "$conf" ] || return 1
  local line user=""
  while IFS= read -r line; do
    case "$line" in
      *agetty*--autologin*)
        user=$(printf '%s' "$line" | sed -E 's/.*--autologin[[:space:]]+([^[:space:]]+).*/\1/')
        ;;
    esac
  done < "$conf"
  [ -n "$user" ] && { printf '%s\n' "$user"; return 0; }
  return 1
}

parse_lightdm_autologin() {
  local conf="/etc/lightdm/lightdm.conf"
  [ -f "$conf" ] || return 1
  local user
  user=$(awk -F= '/^[[:space:]]*autologin-user[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf" 2>/dev/null)
  [ -n "$user" ] && [ "$user" != "root" ] && { printf '%s\n' "$user"; return 0; }
  return 1
}

first_desktop_user_from_passwd() {
  local u uid shell home
  while IFS=: read -r u _ uid _ _ home shell; do
    [ "$uid" -ge 1000 ] 2>/dev/null || continue
    [ "$uid" -lt 60000 ] 2>/dev/null || continue
    case "$shell" in */nologin|*/false|"") continue ;; esac
    [ -d "$home" ] || continue
    printf '%s\n' "$u"
    return 0
  done < /etc/passwd
  return 1
}

active_seat0_user_from_loginctl() {
  command -v loginctl >/dev/null 2>&1 || return 1
  local session user seat active
  while read -r session _ user seat _; do
    [ -n "$session" ] && [ -n "$user" ] || continue
    [ "$user" = "root" ] && continue
    active=$(loginctl show-session "$session" -p Active --value 2>/dev/null | tr '[:upper:]' '[:lower:]') || active=""
    if [ "$active" = "yes" ] && { [ -z "$seat" ] || [ "$seat" = "seat0" ]; }; then
      printf '%s\n' "$user"
      return 0
    fi
  done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
  return 1
}

auto_detect_gui_user() {
  if [ -n "${GUI_USER:-}" ] && [ "$GUI_USER" != "root" ]; then
    return 0
  fi
  local candidate=""
  candidate=$(active_seat0_user_from_loginctl 2>/dev/null || true)
  if [ -z "$candidate" ]; then candidate=$(parse_autologin_conf 2>/dev/null || true); fi
  if [ -z "$candidate" ]; then candidate=$(parse_lightdm_autologin 2>/dev/null || true); fi
  if [ -z "$candidate" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    candidate="$SUDO_USER"
  fi
  if [ -z "$candidate" ] && [ -n "${USER:-}" ] && [ "$USER" != "root" ]; then
    candidate="$USER"
  fi
  if [ -z "$candidate" ]; then candidate=$(first_desktop_user_from_passwd 2>/dev/null || true); fi
  if [ -z "$candidate" ] || [ "$candidate" = "root" ]; then
    echo "Error: could not detect desktop user; set GUI_USER explicitly." >&2
    return 1
  fi
  if ! id -u "$candidate" >/dev/null 2>&1; then
    echo "Error: detected GUI_USER '$candidate' does not exist on system." >&2
    return 1
  fi
  GUI_USER="$candidate"
  export GUI_USER
  return 0
}

# ======================================================================
# Desktop readiness (Wayland/labwc)
# ======================================================================
gui_session_active() {
  command -v loginctl >/dev/null 2>&1 || return 0
  if loginctl show-user "$GUI_USER" -p Sessions --value 2>/dev/null | grep -q '[^[:space:]]'; then
    return 0
  fi
  if loginctl list-sessions --no-legend 2>/dev/null | awk -v user="$GUI_USER" '$3 == user { found=1; exit 0 } END { exit (found?0:1) }'; then
    return 0
  fi
  return 1
}

wait_for_gui_session() {
  local timeout="${GUI_SESSION_WAIT_TIMEOUT:-0}"
  [[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -gt 0 ] || return 0
  command -v loginctl >/dev/null 2>&1 || return 0
  gui_session_active && return 0
  log "Waiting for GUI login session for $GUI_USER (timeout ${timeout}s)…"
  local waited=0
  while [ "$waited" -lt "$timeout" ]; do
    sleep 1
    waited=$((waited + 1))
    if gui_session_active; then
      log "GUI session detected for $GUI_USER after ${waited}s."
      return 0
    fi
  done
  log "GUI session for $GUI_USER not detected after ${timeout}s; continuing anyway."
  return 0
}

_detect_wayland() {
  # Set WAYLAND_DISPLAY if a live socket + matching compositor exist for $1.
  # Echoes "ok" on success, nothing on failure.
  local uid=$1 rt="/run/user/$1" found="" comp=""
  local -a KNOWN=( labwc labwc-pi wayfire sway hyprland river weston )
  if [ -d "$rt" ]; then
    local sock
    for sock in "$rt"/wayland-*; do
      case "$sock" in *.lock) continue ;; esac
      [ -S "$sock" ] && { found=$(basename "$sock"); break; }
    done
  fi
  if [ -n "$found" ]; then
    local p
    for p in "${KNOWN[@]}"; do
      pgrep -u "$uid" -x "$p" >/dev/null 2>&1 && { comp="$p"; break; }
    done
  fi
  [ -n "$found" ] && [ -n "$comp" ] || return 1
  WAYLAND_DISPLAY="$found"
  export WAYLAND_DISPLAY
  SESSION_TYPE="wayland"
  SESSION_COMPOSITOR="$comp"
  return 0
}

_detect_x11() {
  # Find an active X11 DISPLAY that we can talk to. Sets DISPLAY on success.
  local uid=$1 disp=""
  # Candidate list: $DISPLAY if already set, common :0/:1/:2, plus anything
  # that has an X11 socket in /tmp/.X11-unix/.
  local -a candidates=()
  [ -n "${DISPLAY:-}" ] && candidates+=( "$DISPLAY" )
  local sock
  for sock in /tmp/.X11-unix/X*; do
    [ -S "$sock" ] || continue
    candidates+=( ":${sock#/tmp/.X11-unix/X}" )
  done
  # Try each candidate with xset q (cheap identity-free probe).
  local cand
  command -v xset >/dev/null 2>&1 || return 1
  for cand in "${candidates[@]}"; do
    [ -n "$cand" ] || continue
    if DISPLAY="$cand" XAUTHORITY="/home/$GUI_USER/.Xauthority" \
        sudo -n -u "$GUI_USER" env DISPLAY="$cand" \
        XAUTHORITY="/home/$GUI_USER/.Xauthority" xset q >/dev/null 2>&1; then
      disp="$cand"; break
    fi
  done
  [ -n "$disp" ] || return 1
  DISPLAY="$disp"
  export DISPLAY
  : "${XAUTHORITY:=/home/$GUI_USER/.Xauthority}"
  export XAUTHORITY
  SESSION_TYPE="x11"
  SESSION_COMPOSITOR="$(pgrep -u "$uid" -x Xorg >/dev/null 2>&1 && echo Xorg || echo Xwayland)"
  return 0
}

wait_for_display_ready() {
  # Block until either a Wayland compositor (preferred) or an X11 server
  # is reachable. Sets SESSION_TYPE + WAYLAND_DISPLAY or DISPLAY.
  local uid=${1:-$GUI_UID}
  local timeout="${WAYLAND_READY_TIMEOUT:-0}"
  [[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -gt 0 ] || timeout=0
  SESSION_TYPE=""
  local waited=0 announced=no
  while true; do
    if _detect_wayland "$uid"; then
      log "Desktop session ready: wayland socket=$WAYLAND_DISPLAY, compositor=$SESSION_COMPOSITOR."
      return 0
    fi
    if _detect_x11 "$uid"; then
      log "Desktop session ready: X11 DISPLAY=$DISPLAY (session=$SESSION_COMPOSITOR)."
      return 0
    fi
    if [ "$timeout" -gt 0 ] && [ "$waited" -ge "$timeout" ]; then
      log "No Wayland or X11 session detected after ${timeout}s."
      log "Check 'loginctl list-sessions' and that a desktop is logged in."
      return 1
    fi
    if [ "$announced" = "no" ]; then
      log "Waiting for a graphical session (timeout ${timeout}s)…"
      announced=yes
    elif [ "$waited" -gt 0 ] && [ $((waited % 60)) -eq 0 ]; then
      log "Still waiting for a graphical session (waited ${waited}s)…"
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

# Backward-compat shim — older code paths still call wait_for_wayland_ready.
wait_for_wayland_ready() {
  wait_for_display_ready "$@"
}

maybe_defer_launch() {
  [ "$DEFERRED_LAUNCH_DONE" = "true" ] && return
  local delay="${SESSION_READY_DELAY:-0}"
  if [[ "$delay" =~ ^[0-9]+$ ]] && [ "$delay" -gt 0 ]; then
    log "Delaying instance launch for ${delay}s (session warm-up)."
    sleep "$delay"
  fi
  if [ -n "${SESSION_READY_CMD:-}" ]; then
    log "Waiting for SESSION_READY_CMD to succeed…"
    local waited=0 timeout="${SESSION_READY_TIMEOUT:-0}"
    while true; do
      if eval "$SESSION_READY_CMD"; then break; fi
      sleep 1; waited=$((waited + 1))
      if [[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -gt 0 ] && [ "$waited" -ge "$timeout" ]; then
        log "SESSION_READY_CMD timed out after ${waited}s; continuing."
        break
      fi
    done
  fi
  DEFERRED_LAUNCH_DONE=true
}

# ======================================================================
# Output discovery (wlr-randr)
# ======================================================================
as_gui() {
  if [ "${EUID:-$(id -u)}" -eq "${GUI_UID:-999999}" ] 2>/dev/null; then
    "$@"
  else
    sudo -n -u "$GUI_USER" \
      env XDG_RUNTIME_DIR="/run/user/$GUI_UID" \
          WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
          DISPLAY="${DISPLAY:-}" \
          XAUTHORITY="${XAUTHORITY:-/home/$GUI_USER/.Xauthority}" \
          "$@"
  fi
}

_refresh_outputs_x11() {
  OUTPUTS_NAMES=()
  OUTPUT_GEOMETRY=()
  command -v xrandr >/dev/null 2>&1 || return 1
  local line
  while IFS= read -r line; do
    # lines like:  "HDMI-1 connected primary 1920x1080+0+0 ..."
    #        or:  "HDMI-2 connected 1280x720+1920+0 ..."
    [[ "$line" == *" connected "* ]] || continue
    local name geom
    name="${line%% *}"
    geom=$(printf '%s' "$line" | grep -oE '[0-9]+x[0-9]+\+[0-9-]+\+[0-9-]+' | head -1)
    [ -n "$geom" ] || continue
    local w h x y
    w="${geom%%x*}"; rest="${geom#*x}"
    h="${rest%%+*}"; rest="${rest#*+}"
    x="${rest%%+*}"
    y="${rest#*+}"
    OUTPUTS_NAMES+=( "$name" )
    OUTPUT_GEOMETRY["$name"]="$x $y $w $h"
  done < <(as_gui xrandr --query 2>/dev/null)
  if [ "${#OUTPUTS_NAMES[@]}" -gt 1 ]; then
    mapfile -t OUTPUTS_NAMES < <(printf '%s\n' "${OUTPUTS_NAMES[@]}" | LC_ALL=C sort)
  fi
  [ "${#OUTPUTS_NAMES[@]}" -gt 0 ]
}

refresh_outputs() {
  if [ "${SESSION_TYPE:-}" = "x11" ]; then
    _refresh_outputs_x11
    return $?
  fi
  OUTPUTS_NAMES=()
  OUTPUT_GEOMETRY=()
  command -v wlr-randr >/dev/null 2>&1 || return 1
  local json
  json=$(as_gui wlr-randr --json 2>/dev/null) || return 1
  [ -n "$json" ] || return 1
  local parsed
  parsed=$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for o in data:
    if not o.get("enabled"):
        continue
    name = o.get("name", "")
    pos = o.get("position", {}) or {}
    x = int(pos.get("x", 0)); y = int(pos.get("y", 0))
    w = h = 0
    for m in o.get("modes", []):
        if m.get("current"):
            w = int(m.get("width", 0)); h = int(m.get("height", 0))
            break
    if not w or not h:
        for m in o.get("modes", []):
            if m.get("preferred"):
                w = int(m.get("width", 0)); h = int(m.get("height", 0))
                break
    scale = float(o.get("scale", 1.0) or 1.0)
    if scale and scale != 1.0:
        w = int(round(w / scale)); h = int(round(h / scale))
    print(f"{name}\t{x}\t{y}\t{w}\t{h}")
' 2>/dev/null)
  [ -z "$parsed" ] && return 1
  while IFS=$'\t' read -r name x y w h; do
    [ -n "$name" ] || continue
    OUTPUTS_NAMES+=( "$name" )
    OUTPUT_GEOMETRY["$name"]="$x $y $w $h"
  done <<< "$parsed"
  # Sort alphabetically so HDMI-A-1 precedes HDMI-A-2 regardless of the
  # order wlr-randr happened to enumerate them in. This keeps the auto-pick
  # deterministic and the primary display first.
  if [ "${#OUTPUTS_NAMES[@]}" -gt 1 ]; then
    mapfile -t OUTPUTS_NAMES < <(printf '%s\n' "${OUTPUTS_NAMES[@]}" | LC_ALL=C sort)
  fi
  [ "${#OUTPUTS_NAMES[@]}" -gt 0 ]
}

pick_output_for_instance() {
  local id=$1
  local requested="${INSTANCE_OUTPUT[$id]:-}"
  if [ -n "$requested" ] && [ -n "${OUTPUT_GEOMETRY[$requested]:-}" ]; then
    printf '%s\n' "$requested"
    return 0
  fi
  if [ -n "$requested" ]; then
    # stdout is captured by callers — route the notice to stderr.
    log_instance "$id" "requested output '$requested' not connected; leaving slot unfilled" >&2
    # Preserve the user's explicit choice so the main loop can pause until
    # the cable is plugged in again, instead of silently falling back.
    printf '%s\n' "$requested"
    return 1
  fi
  # No explicit request: pick the Nth available output by id order.
  local idx=0 name
  for name in "${OUTPUTS_NAMES[@]}"; do
    idx=$((idx + 1))
    if [ "$idx" = "$id" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  # Only one output — give both instances the same one (with a warning via
  # validate_runtime_config at startup; hotplug loop handles unavailability).
  if [ "${#OUTPUTS_NAMES[@]}" -gt 0 ]; then
    printf '%s\n' "${OUTPUTS_NAMES[0]}"
    return 0
  fi
  return 1
}

resolve_output_geometry() {
  local id=$1
  local name
  name=$(pick_output_for_instance "$id" 2>/dev/null || true)
  if [ -z "$name" ]; then
    # Unknown; default to 0,0 1920x1080
    printf 'HDMI-A-1\t0\t0\t1920\t1080\n'
    return 1
  fi
  INSTANCE_OUTPUT[$id]="$name"
  local geo="${OUTPUT_GEOMETRY[$name]:-}"
  if [ -z "$geo" ]; then
    printf '%s\t0\t0\t1920\t1080\n' "$name"
    return 1
  fi
  set -- $geo
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$1" "$2" "$3" "$4"
  return 0
}

# ======================================================================
# Chromium: profile + extension + launch
# ======================================================================
chromium_binary() {
  if [ -n "$CHROMIUM_BIN" ] && [ -x "$CHROMIUM_BIN" ]; then
    printf '%s\n' "$CHROMIUM_BIN"; return 0
  fi
  local cand
  for cand in /usr/bin/chromium /usr/bin/chromium-browser; do
    [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  command -v chromium >/dev/null 2>&1 && { command -v chromium; return 0; }
  command -v chromium-browser >/dev/null 2>&1 && { command -v chromium-browser; return 0; }
  echo /usr/bin/chromium
}

vlc_binary() {
  if [ -n "$VLC_BIN" ] && [ -x "$VLC_BIN" ]; then
    printf '%s\n' "$VLC_BIN"; return 0
  fi
  local cand
  for cand in /usr/bin/vlc /usr/bin/cvlc; do
    [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  echo /usr/bin/vlc
}

trim_chromium_cache() {
  local base=$1
  rm -rf \
    "$base/Cache" \
    "$base/Code Cache" \
    "$base/GPUCache" \
    "$base/GrShaderCache" \
    "$base/ShaderCache" \
    "$base/DawnCache" \
    "$base/Application Cache" 2>/dev/null || true
}

patch_chromium_prefs() {
  local id=$1
  local profile_root=${INSTANCE_PROFILE_DIR[$id]}
  local profile_dir="$profile_root/Default"
  local url="${INSTANCE_URL[$id]}"
  mkdir -p "$profile_dir"
  local pref="$profile_dir/Preferences"
  local local_state="$profile_root/Local State"
  [ -f "$pref" ] || printf '{}\n' > "$pref"
  PREF_PATH="$pref" STATE_PATH="$local_state" TARGET_URL="$url" python3 <<'PYTHON'
import json, os
def load_json(p):
    try:
        with open(p, 'r', encoding='utf-8') as fh:
            return json.load(fh)
    except (FileNotFoundError, json.JSONDecodeError):
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
dist = prefs.setdefault('distribution', {})
dist['show_welcome_page'] = False
dist['skip_first_run_ui'] = True
with open(pref_path, 'w', encoding='utf-8') as fh:
    json.dump(prefs, fh, indent=2, sort_keys=True)

state = load_json(state_path)
sp = state.setdefault('profile', {})
sp['exit_type'] = 'Normal'
sp.setdefault('last_used', 'Default')
with open(state_path, 'w', encoding='utf-8') as fh:
    json.dump(state, fh, indent=2, sort_keys=True)
PYTHON

  find "$profile_dir" -maxdepth 1 -type f \
    \( -name 'Current *' -o -name 'Last *' -o -name 'Singleton*' -o -name 'Tabs_*' \) \
    -delete 2>/dev/null || true
  rm -rf "$profile_dir/Sessions" "$profile_dir/Session Storage" 2>/dev/null || true
  rm -f "$profile_dir"/Singleton* "$profile_root"/Singleton* 2>/dev/null || true
  trim_chromium_cache "$profile_root"
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    chown -R "$GUI_USER":"$GUI_USER" "$profile_root" 2>/dev/null || true
  fi
}

ensure_frigate_extension() {
  local id=$1
  local autofill="$FRIGATE_BIRDSEYE_AUTO_FILL"
  local dark="$FRIGATE_DARK_MODE" theme="$FRIGATE_THEME"
  # Skip entirely when nothing is customised
  [ "$autofill" = "true" ] || [ -n "$dark" ] || [ -n "$theme" ] || return 1
  local profile_root=${INSTANCE_PROFILE_DIR[$id]}
  local url="${INSTANCE_URL[$id]}"
  local -a candidates=()
  [ -n "$FRIGATE_BIRDSEYE_EXTENSION_DIR" ] && candidates+=( "${FRIGATE_BIRDSEYE_EXTENSION_DIR%/}/$id" )
  candidates+=( "${profile_root%/}/frigate-helper" "/usr/local/share/kiosk-monitor/frigate-helper-$id" )
  local dir="" candidate
  for candidate in "${candidates[@]}"; do
    [ -n "$candidate" ] || continue
    if mkdir -p "$candidate" 2>/dev/null; then dir="$candidate"; break; fi
  done
  [ -n "$dir" ] || return 1
  local match_pattern="$FRIGATE_BIRDSEYE_MATCH_PATTERN"
  [ -z "$match_pattern" ] && match_pattern=$(derive_match_pattern "$url")

  # --- Compute initial CSS fallback dimensions from wlr-randr -----------
  local bw="${FRIGATE_BIRDSEYE_WIDTH:-}" bh="${FRIGATE_BIRDSEYE_HEIGHT:-}"
  local margin="${FRIGATE_BIRDSEYE_MARGIN:-80}"
  [[ "$margin" =~ ^[0-9]+$ ]] || margin=80
  if [ -z "$bw" ] || [ -z "$bh" ]; then
    local out_name="${INSTANCE_OUTPUT[$id]:-}"
    local geo="${OUTPUT_GEOMETRY[$out_name]:-}"
    local ow=1920 oh=1080
    if [ -n "$geo" ]; then
      # shellcheck disable=SC2086
      set -- $geo   # geo = "X Y W H"
      ow="${3:-1920}"
      oh="${4:-1080}"
    fi
    [ -z "$bw" ] && bw=$(( ow > margin ? ow - margin : ow ))
    [ -z "$bh" ] && bh=$(( oh > margin ? oh - margin : oh ))
  fi
  [[ "$bw" =~ ^[0-9]+$ ]] || bw=1800
  [[ "$bh" =~ ^[0-9]+$ ]] || bh=1000
  [ "$bw" -lt 320 ] && bw=320
  [ "$bh" -lt 240 ] && bh=240
  # Ship to stderr — stdout of this function is captured by the caller.
  log_instance "$id" "Birdseye fallback grid ${bw}x${bh} (output=${INSTANCE_OUTPUT[$id]:-?}, JS refines at runtime)" >&2

  # --- CSS: first-paint fallback so there's no flash before JS runs ----
  if [ "$autofill" = "true" ]; then
    cat > "$dir/fullscreen.css" <<CSS
/* Initial dimensions — frigate-helper.js recomputes these from the actual
   window size once the document loads, so this only matters for first paint. */
#pageRoot > div > div > div > div.react-grid-layout.grid-layout {
  height: ${bh}px !important;
  width: ${bw}px !important;
  max-width: ${bw}px !important;
  margin: 0 auto;
}
#pageRoot > div > div > div > div.react-grid-layout.grid-layout > div {
  display: flex;
  flex-direction: column;
  width: 100% !important;
  max-width: ${bw}px !important;
}
#pageRoot > div > div > div > div.react-grid-layout.grid-layout > div > div > div.size-full > div > div > div > canvas {
  height: ${bh}px !important;
  width: ${bw}px !important;
}
CSS
  else
    rm -f "$dir/fullscreen.css"
  fi

  # --- JS: theme + dark mode + runtime birdseye sizing -----------------
  local has_helper_js=0
  if [ -n "$dark" ] || [ -n "$theme" ] || [ "$autofill" = "true" ]; then
    has_helper_js=1
    local esc_dark esc_theme esc_tkey esc_ckey
    esc_dark=$(printf '%s' "$dark"  | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    esc_theme=$(printf '%s' "$theme" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    esc_tkey=$(printf '%s' "$FRIGATE_THEME_STORAGE_KEY" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    esc_ckey=$(printf '%s' "$FRIGATE_COLOR_STORAGE_KEY" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    local js_autofill="false"
    [ "$autofill" = "true" ] && js_autofill="true"
    cat > "$dir/frigate-helper.js" <<JS
(function() {
  var DARK      = "$esc_dark";
  var THEME     = "$esc_theme";
  var TKEY      = "$esc_tkey";
  var CKEY      = "$esc_ckey";
  var AUTOFILL  = $js_autofill;
  var MARGIN    = $margin;
  var GRID_SEL  = "#pageRoot > div > div > div > div.react-grid-layout.grid-layout";

  // Theme storage keys — write the canonical one plus well-known aliases
  // so the Frigate UI picks it up across versions.
  var THEME_ALIASES = [TKEY, "vite-ui-theme", "ui-theme", "theme"];
  var COLOR_ALIASES = [CKEY, "vite-ui-color", "color-scheme", "frigate-color-scheme"];
  function setAll(keys, value) {
    if (!value) return;
    for (var i = 0; i < keys.length; i++) {
      try { localStorage.setItem(keys[i], value); } catch (e) {}
    }
  }
  function applyHtmlClass() {
    var h = document.documentElement;
    if (!h) return;
    if (DARK === "dark")  { h.classList.add("dark");  h.classList.remove("light"); }
    if (DARK === "light") { h.classList.add("light"); h.classList.remove("dark"); }
    if (THEME) {
      var classes = (h.className || "").split(/\s+/).filter(function (c) {
        return c && c.indexOf("theme-") !== 0;
      });
      classes.push("theme-" + THEME);
      h.className = classes.join(" ");
      h.setAttribute("data-theme", THEME);
    }
  }
  function pxImportant(el, prop, px) {
    if (!el || !el.style) return;
    el.style.setProperty(prop, px + "px", "important");
  }
  function resizeBirdseye() {
    if (!AUTOFILL) return;
    var grid = document.querySelector(GRID_SEL);
    if (!grid) return;
    var w = Math.max(320, (window.innerWidth  || document.documentElement.clientWidth  || 1920) - MARGIN);
    var h = Math.max(240, (window.innerHeight || document.documentElement.clientHeight || 1080) - MARGIN);
    pxImportant(grid, "width", w);
    pxImportant(grid, "height", h);
    pxImportant(grid, "max-width", w);
    grid.style.margin = "0 auto";
    var child = grid.firstElementChild;
    if (child) {
      child.style.display = "flex";
      child.style.flexDirection = "column";
      pxImportant(child, "max-width", w);
      child.style.setProperty("width", "100%", "important");
    }
    var canvas = grid.querySelector("canvas");
    if (canvas) {
      pxImportant(canvas, "width",  w);
      pxImportant(canvas, "height", h);
    }
  }
  function applyAll() {
    applyHtmlClass();
    resizeBirdseye();
  }
  setAll(THEME_ALIASES, DARK);
  setAll(COLOR_ALIASES, THEME);
  applyAll();
  document.addEventListener("DOMContentLoaded", applyAll);
  window.addEventListener("resize", resizeBirdseye);
  // Poll while React mounts / remounts the grid; run for ~20s total
  var tries = 0;
  var iv = setInterval(function () {
    applyAll();
    if (++tries > 80) clearInterval(iv);
  }, 250);
})();
JS
  else
    rm -f "$dir/frigate-helper.js" "$dir/frigate-theme.js"
  fi
  # clean up the old file name from previous versions
  [ "$has_helper_js" = "1" ] && rm -f "$dir/frigate-theme.js"

  # --- manifest ---
  local css_field="" js_field=""
  [ "$autofill" = "true" ] && css_field='      "css": ["fullscreen.css"],'
  [ "$has_helper_js" = "1" ] && js_field='      "js": ["frigate-helper.js"],'
  cat > "$dir/manifest.json" <<MANIFEST
{
  "name": "Kiosk-Monitor Frigate Helper",
  "version": "1.0",
  "manifest_version": 3,
  "description": "Inject Frigate kiosk tweaks: birdseye auto-fill, dark-mode and theme.",
  "content_scripts": [
    {
      "matches": ["$match_pattern"],
$css_field
$js_field
      "run_at": "document_start"
    }
  ]
}
MANIFEST
  # Clean up blank lines in the manifest (from skipped css/js fields)
  sed -i '/^[[:space:]]*$/d' "$dir/manifest.json"

  chmod 0755 "$dir"
  find "$dir" -maxdepth 1 -type f -exec chmod 0644 {} +
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    chown -R "$GUI_USER":"$GUI_USER" "$dir" 2>/dev/null || true
  fi
  printf '%s\n' "$dir"
}

# ======================================================================
# Process management helpers
# ======================================================================
cleanup_stray_processes() {
  local id=$1 keep_pid=${2:-}
  local pattern="${INSTANCE_MATCH[$id]:-}"
  [ -n "$pattern" ] || return 0
  local tries=0 pid terminated
  while [ $tries -lt 3 ]; do
    terminated=0
    mapfile -t pids < <(pgrep -u "$GUI_USER" -f -- "$pattern" 2>/dev/null || true)
    for pid in "${pids[@]}"; do
      [ -n "$pid" ] || continue
      [ -n "$keep_pid" ] && [ "$pid" = "$keep_pid" ] && continue
      if kill -0 "$pid" 2>/dev/null; then
        debug_instance "$id" "pruning stray PID $pid (pattern=$pattern)"
        kill "$pid" 2>/dev/null || true
        terminated=1
      fi
    done
    [ $terminated -eq 0 ] && break
    sleep 1
    tries=$((tries + 1))
  done
  # final escalation
  mapfile -t pids < <(pgrep -u "$GUI_USER" -f -- "$pattern" 2>/dev/null || true)
  for pid in "${pids[@]}"; do
    [ -n "$pid" ] || continue
    [ -n "$keep_pid" ] && [ "$pid" = "$keep_pid" ] && continue
    kill -9 "$pid" 2>/dev/null || true
  done
}

process_alive() {
  local pid=$1
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

# ======================================================================
# Per-instance launch / stop
# ======================================================================
launch_chrome_instance() {
  local id=$1
  need_cmd curl
  local chrome
  chrome=$(chromium_binary)
  [ -x "$chrome" ] || { log_instance "$id" "Chromium not found at $chrome"; return 1; }
  need_cmd "$chrome" 2>/dev/null || true
  maybe_defer_launch

  local profile_root=${INSTANCE_PROFILE_DIR[$id]}
  mkdir -p "$profile_root"
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    chown -R "$GUI_USER":"$GUI_USER" "$profile_root" 2>/dev/null || true
  fi
  patch_chromium_prefs "$id"

  # resolve placement
  local geo name x y w h
  geo=$(resolve_output_geometry "$id" || true)
  IFS=$'\t' read -r name x y w h <<< "$geo"

  cleanup_stray_processes "$id"

  local url="${INSTANCE_URL[$id]}"
  local -a flags=(
    --kiosk
    --start-fullscreen
    --no-first-run
    --no-default-browser-check
    --disable-restore-session-state
    --disable-translate
    --disable-infobars
    --disable-session-crashed-bubble
    "--disable-features=TranslateUI,ChromeWhatsNewUI"
    --disable-component-update
    --disable-sync
    --noerrdialogs
    --disable-logging
    --disable-logging-redirect
    --log-level=3
    "--enable-features=OverlayScrollbar,UseOzonePlatform"
    --password-store=basic
    --allow-running-insecure-content
    "--user-data-dir=$profile_root"
    "--window-position=${x},${y}"
    "--window-size=${w},${h}"
    "--class=${INSTANCE_CLASS[$id]}"
    --new-window
  )
  if [ "${SESSION_TYPE:-}" = "x11" ]; then
    flags+=( --ozone-platform=x11 )
  else
    flags+=( --ozone-platform=wayland )
  fi
  local ext_path
  if ext_path=$(ensure_frigate_extension "$id"); then
    flags+=( "--load-extension=$ext_path" "--disable-extensions-except=$ext_path" )
  fi
  [ "$DEVTOOLS_AUTO_OPEN" = "true" ] && flags+=( --auto-open-devtools-for-tabs )
  [ -n "$DEVTOOLS_REMOTE_PORT" ] && flags+=( "--remote-debugging-port=$DEVTOOLS_REMOTE_PORT" )
  flags+=( "$url" )

  log_instance "$id" "Launching Chromium on $name (${w}x${h}+${x}+${y}) → $url"
  as_gui "$chrome" "${flags[@]}" >/dev/null 2>&1 &
  local launcher_pid=$!
  sleep "$CHROME_LAUNCH_DELAY"
  sleep "$CHROME_READY_DELAY"

  # find main browser PID (process with both --type=browser and our user-data-dir)
  local main_pid=""
  main_pid=$(pgrep -u "$GUI_USER" -o -f -- "--user-data-dir=$profile_root .*--type=browser|--type=browser .*--user-data-dir=$profile_root" 2>/dev/null || true)
  if [ -z "$main_pid" ]; then
    main_pid=$(pgrep -u "$GUI_USER" -o -f -- "--user-data-dir=$profile_root" 2>/dev/null | head -1 || true)
  fi
  if [ -z "$main_pid" ] && process_alive "$launcher_pid"; then
    main_pid=$(pgrep -P "$launcher_pid" -n 2>/dev/null || true)
  fi
  [ -z "$main_pid" ] && main_pid="$launcher_pid"
  INSTANCE_PID[$id]="$main_pid"
  log_instance "$id" "Chromium main PID=$main_pid (launcher=$launcher_pid)"
  return 0
}

launch_vlc_instance() {
  local id=$1
  local vlc
  vlc=$(vlc_binary)
  [ -x "$vlc" ] || { log_instance "$id" "VLC not found at $vlc"; return 1; }
  maybe_defer_launch

  local geo name x y w h
  geo=$(resolve_output_geometry "$id" || true)
  IFS=$'\t' read -r name x y w h <<< "$geo"

  cleanup_stray_processes "$id"

  local url="${INSTANCE_URL[$id]}"
  local logfile="/tmp/kiosk-monitor-vlc-${id}.log"
  # ensure we can write the logfile as the GUI user
  : > "$logfile" 2>/dev/null || true
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    chown "$GUI_USER":"$GUI_USER" "$logfile" 2>/dev/null || true
  fi

  local -a flags=(
    --intf=dummy
    --no-qt-privacy-ask
    --no-video-title-show
    "--video-title=${INSTANCE_CLASS[$id]}"
    --quiet
    --file-logging
    "--logfile=$logfile"
    --fullscreen
    --video-on-top
    "--video-x=${x}"
    "--video-y=${y}"
    "--width=${w}"
    "--height=${h}"
  )
  [ "$VLC_LOOP" = "true" ] && flags+=( --loop )
  [ "$VLC_NO_AUDIO" = "true" ] && flags+=( --no-audio )
  if [ -n "$VLC_NETWORK_CACHING" ]; then
    flags+=( "--network-caching=$VLC_NETWORK_CACHING" )
  fi
  if [ -n "$VLC_EXTRA_ARGS" ]; then
    # shellcheck disable=SC2206
    local -a extra=( $VLC_EXTRA_ARGS )
    flags+=( "${extra[@]}" )
  fi
  flags+=( "$url" )

  log_instance "$id" "Launching VLC on $name (${w}x${h}+${x}+${y}) → $url"
  # exec -a sets argv[0] so the process (and its X11 WM_CLASS res_name in
  # most toolkits) matches ${INSTANCE_CLASS[$id]}, which lines up with the
  # labwc window rule below.
  local esc_cmd
  printf -v esc_cmd 'exec -a %q %q' "${INSTANCE_CLASS[$id]}" "$vlc"
  local f
  for f in "${flags[@]}"; do
    printf -v esc_cmd '%s %q' "$esc_cmd" "$f"
  done
  as_gui bash -c "$esc_cmd" >/dev/null 2>&1 &
  local launcher_pid=$!
  sleep "$VLC_LAUNCH_DELAY"

  # under sudo, $! is the sudo PID — find the actual vlc
  local pid=""
  pid=$(pgrep -u "$GUI_USER" -o -f -- "--logfile=$logfile" 2>/dev/null || true)
  [ -z "$pid" ] && pid="$launcher_pid"
  INSTANCE_PID[$id]="$pid"
  log_instance "$id" "VLC PID=$pid (launcher=$launcher_pid)"
  return 0
}

launch_instance() {
  local id=$1
  case "${INSTANCE_MODE[$id]}" in
    chrome) launch_chrome_instance "$id" ;;
    vlc)    launch_vlc_instance "$id" ;;
    *)      log_instance "$id" "Unknown mode: ${INSTANCE_MODE[$id]}"; return 1 ;;
  esac
}

stop_instance() {
  local id=$1
  local pid="${INSTANCE_PID[$id]:-}"
  if process_alive "$pid"; then
    log_instance "$id" "Stopping PID $pid"
    kill "$pid" 2>/dev/null || true
    local waited=0
    while process_alive "$pid"; do
      sleep 1
      waited=$((waited + 1))
      [ "$waited" -ge 8 ] && { kill -9 "$pid" 2>/dev/null || true; break; }
    done
  fi
  cleanup_stray_processes "$id"
  INSTANCE_PID[$id]=""
}

# ======================================================================
# Health & freeze detection
# ======================================================================
health_check_instance() {
  local id=$1
  # VLC streams often don't answer HEAD/GET sanely (GCS returns 403, RTSP has
  # no HTTP at all), so rely on process liveness and frame-freeze for vlc.
  [ "${INSTANCE_MODE[$id]}" = "vlc" ] && return 0
  local url="${INSTANCE_URL[$id]}"
  case "$url" in
    http://*|https://*) ;;
    *) return 0 ;;
  esac
  local connect="${HEALTH_CONNECT_TIMEOUT:-3}"
  local total="${HEALTH_TOTAL_TIMEOUT:-8}"
  local code cmd
  for mode in head get; do
    if [ "$mode" = head ]; then
      cmd=( curl -sS -I --connect-timeout "$connect" --max-time "$total" -o /dev/null -w "%{http_code}" "$url" )
    else
      cmd=( curl -sS --connect-timeout "$connect" --max-time "$total" -o /dev/null -w "%{http_code}" "$url" )
    fi
    code=$("${cmd[@]}" 2>/dev/null || echo 000)
    debug_instance "$id" "health ${mode^^} -> $code"
    [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 400 ] 2>/dev/null && return 0
  done
  log_instance "$id" "Health check failed for $url (last HTTP $code)"
  return 1
}

wait_for_url_ready_instance() {
  local id=$1
  [ "${INSTANCE_MODE[$id]}" = "vlc" ] && return 0
  local url="${INSTANCE_URL[$id]}"
  case "$url" in http://*|https://*) ;; *) return 0 ;; esac
  local timeout="${WAIT_FOR_URL_TIMEOUT:-0}"
  local waited=0
  while true; do
    if health_check_instance "$id"; then
      log_instance "$id" "Target $url reachable — continuing."
      return 0
    fi
    log_instance "$id" "target $url still down…"
    sleep 1
    waited=$((waited + 1))
    if [ "$timeout" -gt 0 ] && [ "$waited" -ge "$timeout" ]; then
      log_instance "$id" "Health check still failing after ${timeout}s — continuing anyway."
      return 1
    fi
  done
}

capture_output_hash() {
  local id=$1
  local name="${INSTANCE_OUTPUT[$id]:-}"
  local tmp
  tmp=$(mktemp 2>/dev/null) || return 1
  if [ "${SESSION_TYPE:-}" = "x11" ]; then
    # xwd captures the whole root; per-output capture would need scrot/maim
    # with geometry. For now, hash the full root — works on single-display
    # X11 setups and gracefully degrades on multi-display.
    if ! as_gui xwd -silent -root -display "$DISPLAY" >"$tmp" 2>/dev/null; then
      debug_instance "$id" "xwd capture failed (DISPLAY=$DISPLAY)"
      rm -f "$tmp"; return 1
    fi
  else
    local -a cmd=( as_gui grim )
    [ -n "$name" ] && cmd+=( -o "$name" )
    cmd+=( -t ppm - )
    if ! "${cmd[@]}" >"$tmp" 2>/dev/null; then
      debug_instance "$id" "grim capture failed (output=$name)"
      rm -f "$tmp"; return 1
    fi
  fi
  local hash
  hash=$(HASH_MODE="$SCREEN_SAMPLE_MODE" python3 - "$tmp" <<'PY' 2>/dev/null
import hashlib, os, sys
MODE = os.environ.get("HASH_MODE","sample").strip().lower()
if MODE not in ("sample","full"):
    MODE = "sample"
def half_or_full(v): return v if MODE=="full" else (v//2 if v>1 else v)
def hash_ppm(path):
    with open(path,"rb") as fh:
        magic = fh.read(2)
        if magic != b"P6":
            return None
        def read_token():
            tok = bytearray()
            while True:
                ch = fh.read(1)
                if not ch: return None
                if ch == b"#":
                    fh.readline(); continue
                if ch in b" \t\r\n":
                    if tok: return tok.decode("ascii")
                    continue
                tok.append(ch[0])
        def skip_ws():
            while True:
                ch = fh.read(1)
                if not ch: return
                if ch not in b" \t\r\n":
                    fh.seek(-1,1); return
        wt = read_token(); ht = read_token(); mt = read_token()
        if not wt or not ht or not mt: return None
        w = int(wt); h = int(ht); mv = int(mt)
        if w<=0 or h<=0: return None
        bpc = 2 if mv>255 else 1
        skip_ws()
        rw = half_or_full(w); rh = half_or_full(h)
        row_bytes = w*3*bpc; region = rw*3*bpc
        hasher = hashlib.sha256()
        for r in range(h):
            row = fh.read(row_bytes)
            if len(row) != row_bytes: return None
            if r < rh:
                hasher.update(row[:region])
        return hasher.hexdigest()
digest = hash_ppm(sys.argv[1])
if digest is None:
    raise SystemExit(1)
print(digest)
PY
)
  hash=$(printf '%s' "$hash" | tr -d '[:space:]')
  if [ -z "$hash" ]; then
    if [ "$SCREEN_SAMPLE_MODE" = "full" ]; then
      hash=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')
    else
      hash=$(head -c "$SCREEN_SAMPLE_BYTES" "$tmp" 2>/dev/null | sha256sum | awk '{print $1}')
    fi
  fi
  rm -f "$tmp"
  [ -n "$hash" ] || return 1
  printf '%s\n' "$hash"
}

# ======================================================================
# Restart bookkeeping
# ======================================================================
record_restart_instance() {
  local id=$1
  stop_instance "$id"
  local now; now=$(date +%s)
  local log="${INSTANCE_RESTART_LOG[$id]:-}"
  local entry new=""
  for entry in $log; do
    if [ $((now - entry)) -le "$RESTART_WINDOW" ]; then
      new+=" $entry"
    fi
  done
  new+=" $now"
  INSTANCE_RESTART_LOG[$id]="${new# }"
  local count; count=$(printf '%s\n' "${INSTANCE_RESTART_LOG[$id]}" | wc -w)
  if [ "$count" -gt "$MAX_RESTARTS" ]; then
    log_instance "$id" "Too many restarts ($count in ${RESTART_WINDOW}s) — backing off 5 minutes"
    sleep 300
    INSTANCE_RESTART_LOG[$id]=""
  fi
  refresh_outputs || true
  launch_instance "$id" || log_instance "$id" "relaunch failed; will retry"
  INSTANCE_LAST_HASH[$id]=""
  INSTANCE_STALL_COUNT[$id]=0
  INSTANCE_FAIL_COUNT[$id]=0
  INSTANCE_LAST_GOOD[$id]=$(date +%s)
  if health_check_instance "$id"; then
    INSTANCE_FAIL_COUNT[$id]=0
  fi
}

# ======================================================================
# Instance configuration
# ======================================================================
setup_instances() {
  INSTANCES=( 1 )
  INSTANCE_MODE[1]="$MODE"
  INSTANCE_URL[1]="$URL"
  INSTANCE_OUTPUT[1]="$OUTPUT"
  INSTANCE_FORCE_RESOLUTION[1]="$FORCE_RESOLUTION"
  INSTANCE_FORCE_ROTATION[1]="$FORCE_ROTATION"
  if [ -n "$MODE2" ]; then
    INSTANCES+=( 2 )
    INSTANCE_MODE[2]="$MODE2"
    INSTANCE_URL[2]="${URL2:-$URL}"
    INSTANCE_OUTPUT[2]="$OUTPUT2"
    INSTANCE_FORCE_RESOLUTION[2]="$FORCE_RESOLUTION_2"
    INSTANCE_FORCE_ROTATION[2]="$FORCE_ROTATION_2"
  fi
  local id
  for id in "${INSTANCES[@]}"; do
    INSTANCE_PID[$id]=""
    INSTANCE_LAST_HASH[$id]=""
    INSTANCE_STALL_COUNT[$id]=0
    INSTANCE_FAIL_COUNT[$id]=0
    INSTANCE_LAST_GOOD[$id]=$(date +%s)
    INSTANCE_RESTART_LOG[$id]=""
    INSTANCE_PAUSED[$id]="no"
    # Window identifier used by launch flags and labwc window rules
    INSTANCE_CLASS[$id]="kiosk-monitor-${INSTANCE_MODE[$id]}-$id"
    case "${INSTANCE_MODE[$id]}" in
      chrome)
        INSTANCE_PROFILE_DIR[$id]="${PROFILE_RUNTIME_ROOT%/}/chromium-$id"
        INSTANCE_MATCH[$id]="--user-data-dir=$(regex_escape "${INSTANCE_PROFILE_DIR[$id]}")"
        INSTANCE_STALL_THRESHOLD[$id]=$STALL_RETRIES
        ;;
      vlc)
        INSTANCE_PROFILE_DIR[$id]="${PROFILE_RUNTIME_ROOT%/}/vlc-$id"
        INSTANCE_MATCH[$id]="--logfile=/tmp/kiosk-monitor-vlc-${id}\.log"
        INSTANCE_STALL_THRESHOLD[$id]=$VLC_STALL_RETRIES
        ;;
    esac
  done
}

validate_runtime_config() {
  local errors=0
  # instance 1
  case "$MODE" in
    chrome|vlc) ;;
    *) echo "Config error: MODE must be 'chrome' or 'vlc' (got '$MODE')" >&2; errors=$((errors+1)) ;;
  esac
  if [ -z "${URL:-}" ]; then
    echo "Config error: URL is required for instance 1." >&2
    errors=$((errors+1))
  else
    case "$URL" in
      http://*|https://*|rtsp://*|rtsps://*|rtmp://*|rtmps://*|udp://*|file://*|/*) ;;
      *) echo "Config warning: URL='$URL' has no recognised scheme." >&2 ;;
    esac
  fi
  # instance 2
  if [ -n "${MODE2:-}" ]; then
    case "$MODE2" in
      chrome|vlc) ;;
      *) echo "Config error: MODE2 must be 'chrome', 'vlc', or empty (got '$MODE2')" >&2; errors=$((errors+1)) ;;
    esac
    if [ -z "${URL2:-}" ]; then
      echo "Config error: URL2 is required when MODE2 is set." >&2
      errors=$((errors+1))
    else
      case "$URL2" in
        http://*|https://*|rtsp://*|rtsps://*|rtmp://*|rtmps://*|udp://*|file://*|/*) ;;
        *) echo "Config warning: URL2='$URL2' has no recognised scheme." >&2 ;;
      esac
    fi
    if [ -n "${OUTPUT:-}" ] && [ -n "${OUTPUT2:-}" ] && [ "$OUTPUT" = "$OUTPUT2" ]; then
      echo "Config warning: OUTPUT and OUTPUT2 are both '$OUTPUT'; the two instances will overlap on the same display." >&2
    fi
  fi
  if [ "$errors" -gt 0 ]; then
    echo "Refusing to start — please fix $errors config error(s) in $CONFIG_FILE." >&2
    return 1
  fi
  return 0
}

instance_output_present() {
  # returns 0 if the instance's requested output name is currently in OUTPUTS_NAMES
  local id=$1
  local req="${INSTANCE_OUTPUT[$id]:-}"
  [ -n "$req" ] || return 0          # auto-pick: caller handles fallback
  local name
  for name in "${OUTPUTS_NAMES[@]}"; do
    [ "$name" = "$req" ] && return 0
  done
  return 1
}

valid_rotation() {
  case "$1" in
    normal|90|180|270|flipped|flipped-90|flipped-180|flipped-270) return 0 ;;
    *) return 1 ;;
  esac
}

current_output_mode() {
  # Prints "WxH@FREQ" for a connected output, or empty if unknown.
  local out=$1 json
  command -v wlr-randr >/dev/null 2>&1 || return 1
  json=$(as_gui wlr-randr --json 2>/dev/null) || return 1
  printf '%s' "$json" | NAME="$out" python3 -c '
import json, os, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
target = os.environ.get("NAME", "")
for o in data:
    if o.get("name") != target:
        continue
    for m in o.get("modes", []):
        if m.get("current"):
            w = int(m.get("width", 0))
            h = int(m.get("height", 0))
            r = float(m.get("refresh", 0))
            print("%dx%d@%.3f" % (w, h, r))
            sys.exit(0)
' 2>/dev/null
}

current_output_transform() {
  local out=$1 json
  command -v wlr-randr >/dev/null 2>&1 || return 1
  json=$(as_gui wlr-randr --json 2>/dev/null) || return 1
  printf '%s' "$json" | NAME="$out" python3 -c '
import json, os, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
target = os.environ.get("NAME", "")
for o in data:
    if o.get("name") == target:
        print(o.get("transform", "normal") or "normal")
        sys.exit(0)
' 2>/dev/null
}

ensure_labwc_window_rules() {
  # Generate ~/.config/labwc/rc.xml with window rules that route each kiosk
  # window to its configured output. Under Wayland the client can't choose
  # its output — the compositor decides — so we have to tell labwc.
  #
  # Only writes the file when it doesn't exist yet or when a previous
  # kiosk-monitor run placed the managed marker. Anything else is left
  # alone so we don't clobber a user's hand-rolled compositor config.
  #
  # Single-instance setups never need this — labwc's default placement
  # already puts the sole window on the primary output, so skip the
  # file entirely and leave the compositor config untouched.
  [ "${SESSION_TYPE:-}" = "wayland" ] || return 0
  if [ "${#INSTANCES[@]}" -le 1 ]; then
    return 0
  fi
  local rc="/home/${GUI_USER}/.config/labwc/rc.xml"
  local rc_dir
  rc_dir=$(dirname "$rc")
  local marker="kiosk-monitor: managed rc.xml"

  if ! as_gui mkdir -p "$rc_dir" 2>/dev/null; then
    log "Warning: could not create $rc_dir — skipping labwc window rules."
    return 0
  fi

  if [ -f "$rc" ] && ! grep -qF "$marker" "$rc" 2>/dev/null; then
    log "Warning: $rc exists and isn't kiosk-monitor-managed; leaving it."
    log "Dual-display window routing needs labwc window rules in that file."
    return 0
  fi

  local tmp
  tmp=$(mktemp)
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!-- %s — remove this comment to opt out of auto-management -->\n' "$marker"
    printf '<labwc_config>\n'
    printf '  <windowRules>\n'
    local id
    for id in "${INSTANCES[@]}"; do
      local out="${INSTANCE_OUTPUT[$id]:-}"
      local cls="${INSTANCE_CLASS[$id]:-}"
      local mode="${INSTANCE_MODE[$id]}"
      [ -n "$out" ] && [ -n "$cls" ] || continue
      # Chromium is a Wayland-native client and respects --class=NAME, which
      # labwc matches via 'identifier'. VLC runs under Xwayland and its
      # WM_CLASS is fixed to 'vlc' by Qt regardless of argv[0], so we match
      # the window title instead (set via --video-title).
      if [ "$mode" = "vlc" ]; then
        printf '    <windowRule title="%s" serverDecoration="no" skipTaskbar="yes" skipWindowSwitcher="yes">\n' "$cls"
      else
        printf '    <windowRule identifier="%s" serverDecoration="no" skipTaskbar="yes" skipWindowSwitcher="yes">\n' "$cls"
      fi
      printf '      <action name="MoveToOutput" output="%s"/>\n' "$out"
      printf '    </windowRule>\n'
    done
    printf '  </windowRules>\n'
    printf '</labwc_config>\n'
  } > "$tmp"
  as_gui install -m 0644 "$tmp" "$rc"
  rm -f "$tmp"
  if pkill -SIGHUP -u "$GUI_USER" -x labwc 2>/dev/null; then
    log "labwc window rules written to $rc and compositor reloaded."
  else
    log "labwc window rules written to $rc (could not SIGHUP labwc)."
  fi
}

apply_display_overrides() {
  # Force the requested output's mode and/or transform via wlr-randr.
  # Skips the call entirely when the output is already in the requested
  # state — important because wlr-randr mode changes can trigger kanshi
  # to auto-save a persistent config.init that hijacks the desktop layout.
  local id=$1
  local out="${INSTANCE_OUTPUT[$id]:-}"
  local mode="${INSTANCE_FORCE_RESOLUTION[$id]:-}"
  local rot="${INSTANCE_FORCE_ROTATION[$id]:-}"
  [ -n "$out" ] || return 0
  [ -n "$mode" ] || [ -n "$rot" ] || return 0
  if [ "${SESSION_TYPE:-}" = "x11" ]; then
    command -v xrandr >/dev/null 2>&1 || return 0
    local -a args=( --output "$out" )
    [ -n "$mode" ] && args+=( --mode "${mode%@*}" )
    case "$rot" in
      ""|normal) ;;
      90)  args+=( --rotate left ) ;;
      180) args+=( --rotate inverted ) ;;
      270) args+=( --rotate right ) ;;
      *)   log_instance "$id" "X11: rotation '$rot' not directly supported; skipping" ;;
    esac
    if [ "${#args[@]}" -gt 2 ]; then
      log_instance "$id" "applying display override: xrandr ${args[*]}"
      as_gui xrandr "${args[@]}" >/dev/null 2>&1 \
        || log_instance "$id" "xrandr override failed"
      refresh_outputs || true
    fi
    return 0
  fi
  command -v wlr-randr >/dev/null 2>&1 || return 0

  local mode_valid="no" rot_valid="no"
  if [ -n "$mode" ]; then
    if [[ "$mode" =~ ^[0-9]+x[0-9]+(@[0-9]+(\.[0-9]+)?)?$ ]]; then
      mode_valid="yes"
    else
      log_instance "$id" "ignoring invalid FORCE_RESOLUTION='$mode' (expected WxH or WxH@RATE)"
    fi
  fi
  if [ -n "$rot" ]; then
    if valid_rotation "$rot"; then
      rot_valid="yes"
    else
      log_instance "$id" "ignoring invalid FORCE_ROTATION='$rot' (expected normal|90|180|270|flipped*)"
    fi
  fi
  [ "$mode_valid" = "yes" ] || [ "$rot_valid" = "yes" ] || return 0

  # Idempotency check: compare current vs desired before invoking wlr-randr.
  local need_mode="no" need_rot="no"
  if [ "$mode_valid" = "yes" ]; then
    local cur_mode
    cur_mode=$(current_output_mode "$out" || true)
    local want_dim="${mode%@*}"
    local cur_dim="${cur_mode%@*}"
    if [ "$cur_dim" != "$want_dim" ]; then
      need_mode="yes"
    elif [[ "$mode" == *@* ]]; then
      # compare requested rate (optional) with current rate
      local want_rate="${mode#*@}" cur_rate="${cur_mode#*@}"
      # normalize to integers of Hz*1000 for loose equality
      local w_ms c_ms
      w_ms=$(awk -v v="$want_rate" 'BEGIN{printf "%d", v*1000}')
      c_ms=$(awk -v v="$cur_rate"  'BEGIN{printf "%d", v*1000}')
      [ "$w_ms" != "$c_ms" ] && need_mode="yes"
    fi
  fi
  if [ "$rot_valid" = "yes" ]; then
    local cur_rot
    cur_rot=$(current_output_transform "$out" || true)
    [ "$cur_rot" != "$rot" ] && need_rot="yes"
  fi
  if [ "$need_mode" != "yes" ] && [ "$need_rot" != "yes" ]; then
    debug_instance "$id" "display override already in effect (mode=$mode rot=$rot) — skipping wlr-randr"
    return 0
  fi

  local -a args=( --output "$out" )
  [ "$need_mode" = "yes" ] && args+=( --mode "$mode" )
  [ "$need_rot"  = "yes" ] && args+=( --transform "$rot" )
  log_instance "$id" "applying display override: wlr-randr ${args[*]}"
  if ! as_gui wlr-randr "${args[@]}" >/dev/null 2>&1; then
    log_instance "$id" "wlr-randr override failed (output may not support requested mode/transform)"
  fi
  refresh_outputs || true
}

# ======================================================================
# Profile runtime (Chromium tmpfs staging)
# ======================================================================
prepare_profile_runtime() {
  local runtime="$PROFILE_PERSIST_ROOT"
  if [ "$PROFILE_TMPFS" = "true" ]; then
    runtime="${PROFILE_TMPFS_PATH:-/dev/shm/kiosk-monitor}"
    mkdir -p "$runtime"
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
      chown "$GUI_USER":"$GUI_USER" "$runtime" 2>/dev/null || true
    fi
    if [ -n "$PROFILE_ARCHIVE" ] && extract_archive "$PROFILE_ARCHIVE" "$runtime"; then
      :
    else
      mirror_tree "$PROFILE_PERSIST_ROOT" "$runtime"
    fi
  else
    mkdir -p "$runtime"
  fi
  PROFILE_RUNTIME_ROOT="$runtime"
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    chown -R "$GUI_USER":"$GUI_USER" "$PROFILE_RUNTIME_ROOT" 2>/dev/null || true
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

start_profile_sync_timer() {
  [ "$PROFILE_TMPFS" = "true" ] && [ "$PROFILE_SYNC_BACK" = "true" ] || return 0
  [[ "$PROFILE_SYNC_INTERVAL" =~ ^[0-9]+$ ]] && [ "$PROFILE_SYNC_INTERVAL" -gt 0 ] || return 0
  (
    while true; do
      sleep "$PROFILE_SYNC_INTERVAL" || break
      sync_profile_persist
    done
  ) &
  PROFILE_SYNC_PID=$!
}

# ======================================================================
# Install / update / remove / reconfig
# ======================================================================
write_service_unit() {
  local gui_user=$1 runtime_dir=$2 wayland_display=$3 target_path=${4:-$SERVICE_PATH} dependency=${5:-}
  local after_targets="network-online.target graphical.target"
  [ -n "$dependency" ] && after_targets="$after_targets $dependency"
  local tmp
  tmp=$(mktemp)
  {
    cat <<EOF
[Unit]
Description=Kiosk Monitor Watchdog (Chromium + VLC, dual-display)
Documentation=https://github.com/extremeshok/kiosk-monitor
After=$after_targets
Wants=network-online.target
EOF
    [ -n "$dependency" ] && printf 'Requires=%s\n' "$dependency"
    cat <<'EOF'
StartLimitIntervalSec=0
StartLimitBurst=0

[Service]
Type=simple
EOF
    cat <<EOF
User=$gui_user
Environment=GUI_USER=$gui_user
Environment=XDG_RUNTIME_DIR=$runtime_dir
EOF
    [ -n "$wayland_display" ] && printf 'Environment=WAYLAND_DISPLAY=%s\n' "$wayland_display"
    cat <<EOF
EnvironmentFile=-$CONFIG_FILE
ExecStart=$INSTALL_DIR/kiosk-monitor --run
ExecStop=/bin/kill -s TERM \$MAINPID
ExecReload=/bin/kill -s HUP \$MAINPID
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
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-enabled --quiet tailscaled.service >/dev/null 2>&1 && { printf 'tailscaled.service\n'; return 0; }
  return 1
}

install_bash_completion() {
  # Install bash completion file. Prefers a local copy alongside the script
  # (checkout / --update --local), falls back to downloading from BASE_URL
  # (one-liner curl-pipe install).
  local script_dir=$1
  local target="/etc/bash_completion.d/kiosk-monitor"
  [ -d /etc/bash_completion.d ] || return 0
  local src="$script_dir/kiosk-monitor.bash-completion"
  if [ -f "$src" ]; then
    install -m 0644 "$src" "$target"
    return 0
  fi
  download_component kiosk-monitor.bash-completion "$target" 0644 2>/dev/null || true
  return 0
}

ensure_script_installed() {
  # Installed name is `kiosk-monitor` (no `.sh`). Any leftover
  # `kiosk-monitor.sh` from older installs is removed — no compat alias is
  # maintained going forward.
  local source=$1 target=$2 dir
  dir=$(dirname "$target"); mkdir -p "$dir"
  [ -L "$target" ] && rm -f "$target"
  local source_real target_real=""
  source_real=$(readlink -f "$source" 2>/dev/null || printf '%s' "$source")
  target_real=$(readlink -f "$target" 2>/dev/null || printf '')
  if [ -n "$target_real" ] && [ "$source_real" = "$target_real" ]; then
    chmod 0755 "$target"
  else
    install -m 0755 "$source" "$target"
  fi
  rm -f "${target}.sh"
}

escape_config_value() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

emit_config_line() {
  printf '%s="%s"\n' "$1" "$(escape_config_value "$2")"
}

write_effective_config_file() {
  local target=$1
  need_cmd install
  mkdir -p "$(dirname "$target")"
  local tmp
  tmp=$(mktemp)
  {
    cat <<'EOF'
# kiosk-monitor configuration (generated by --reconfig)
# Edit values as needed and restart the kiosk-monitor service.
EOF
    emit_config_line GUI_USER     "${GUI_USER:-}"
    emit_config_line MODE         "${MODE:-chrome}"
    emit_config_line URL          "${URL:-$DEFAULT_URL}"
    emit_config_line OUTPUT       "${OUTPUT:-}"
    emit_config_line FORCE_RESOLUTION "${FORCE_RESOLUTION:-}"
    emit_config_line FORCE_ROTATION   "${FORCE_ROTATION:-}"
    emit_config_line MODE2        "${MODE2:-}"
    emit_config_line URL2         "${URL2:-}"
    emit_config_line OUTPUT2      "${OUTPUT2:-}"
    emit_config_line FORCE_RESOLUTION_2 "${FORCE_RESOLUTION_2:-}"
    emit_config_line FORCE_ROTATION_2   "${FORCE_ROTATION_2:-}"
    emit_config_line DEBUG        "${DEBUG:-false}"
    emit_config_line CHROMIUM_BIN "${CHROMIUM_BIN:-}"
    emit_config_line VLC_BIN      "${VLC_BIN:-}"
    emit_config_line VLC_LOOP     "${VLC_LOOP:-true}"
    emit_config_line VLC_NO_AUDIO "${VLC_NO_AUDIO:-false}"
    emit_config_line VLC_NETWORK_CACHING "${VLC_NETWORK_CACHING:-}"
    emit_config_line VLC_EXTRA_ARGS "${VLC_EXTRA_ARGS:-}"
    emit_config_line PROFILE_ROOT "${PROFILE_ROOT:-}"
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
    emit_config_line GUI_SESSION_WAIT_TIMEOUT "${GUI_SESSION_WAIT_TIMEOUT:-300}"
    emit_config_line WAYLAND_READY_TIMEOUT "${WAYLAND_READY_TIMEOUT:-300}"
    emit_config_line WAIT_FOR_URL "${WAIT_FOR_URL:-true}"
    emit_config_line WAIT_FOR_URL_TIMEOUT "${WAIT_FOR_URL_TIMEOUT:-0}"
    emit_config_line MIN_UPTIME_BEFORE_START "${MIN_UPTIME_BEFORE_START:-60}"
    emit_config_line CHROME_LAUNCH_DELAY "${CHROME_LAUNCH_DELAY:-3}"
    emit_config_line CHROME_READY_DELAY "${CHROME_READY_DELAY:-2}"
    emit_config_line VLC_LAUNCH_DELAY "${VLC_LAUNCH_DELAY:-3}"
    emit_config_line SCREEN_DELAY "${SCREEN_DELAY:-120}"
    emit_config_line SCREEN_SAMPLE_MODE "${SCREEN_SAMPLE_MODE:-sample}"
    emit_config_line SCREEN_SAMPLE_BYTES "${SCREEN_SAMPLE_BYTES:-524288}"
    emit_config_line HEALTH_INTERVAL "${HEALTH_INTERVAL:-30}"
    emit_config_line HEALTH_CONNECT_TIMEOUT "${HEALTH_CONNECT_TIMEOUT:-3}"
    emit_config_line HEALTH_TOTAL_TIMEOUT "${HEALTH_TOTAL_TIMEOUT:-8}"
    emit_config_line STALL_RETRIES "${STALL_RETRIES:-3}"
    emit_config_line VLC_STALL_RETRIES "${VLC_STALL_RETRIES:-6}"
    emit_config_line HEALTH_RETRIES "${HEALTH_RETRIES:-6}"
    emit_config_line RESTART_WINDOW "${RESTART_WINDOW:-600}"
    emit_config_line MAX_RESTARTS "${MAX_RESTARTS:-10}"
    emit_config_line CLEAN_RESET "${CLEAN_RESET:-600}"
    emit_config_line FRIGATE_BIRDSEYE_AUTO_FILL "${FRIGATE_BIRDSEYE_AUTO_FILL:-false}"
    emit_config_line FRIGATE_BIRDSEYE_WIDTH  "${FRIGATE_BIRDSEYE_WIDTH:-}"
    emit_config_line FRIGATE_BIRDSEYE_HEIGHT "${FRIGATE_BIRDSEYE_HEIGHT:-}"
    emit_config_line FRIGATE_BIRDSEYE_MARGIN "${FRIGATE_BIRDSEYE_MARGIN:-80}"
    emit_config_line FRIGATE_BIRDSEYE_MATCH_PATTERN "${FRIGATE_BIRDSEYE_MATCH_PATTERN:-}"
    emit_config_line FRIGATE_BIRDSEYE_EXTENSION_DIR "${FRIGATE_BIRDSEYE_EXTENSION_DIR:-}"
    emit_config_line FRIGATE_DARK_MODE "${FRIGATE_DARK_MODE:-}"
    emit_config_line FRIGATE_THEME "${FRIGATE_THEME:-}"
    emit_config_line FRIGATE_THEME_STORAGE_KEY "${FRIGATE_THEME_STORAGE_KEY:-frigate-ui-theme}"
    emit_config_line FRIGATE_COLOR_STORAGE_KEY "${FRIGATE_COLOR_STORAGE_KEY:-frigate-ui-color-scheme}"
    emit_config_line DEVTOOLS_AUTO_OPEN "${DEVTOOLS_AUTO_OPEN:-false}"
    emit_config_line DEVTOOLS_REMOTE_PORT "${DEVTOOLS_REMOTE_PORT:-}"
    emit_config_line LOCK_FILE "${LOCK_FILE:-/var/lock/kiosk-monitor.lock}"
    emit_config_line INSTALL_DIR "${INSTALL_DIR:-/usr/local/bin}"
    emit_config_line SERVICE_PATH "${SERVICE_PATH:-/etc/systemd/system/kiosk-monitor.service}"
    emit_config_line BASE_URL "${BASE_URL:-$DEFAULT_BASE_URL}"
    emit_config_line LOG_MAX_BYTES "${LOG_MAX_BYTES:-2097152}"
    emit_config_line LOG_ROTATE_KEEP "${LOG_ROTATE_KEEP:-1}"
  } > "$tmp"
  install -m 0644 "$tmp" "$target"
  rm -f "$tmp"
}

render_config_file() {
  # Initial seed: write a concise sample; user can flesh out later
  local target="$CONFIG_FILE"
  local tmp
  mkdir -p "$CONFIG_DIR"
  tmp=$(mktemp)
  {
    cat <<'EOF'
# kiosk-monitor configuration
# Minimum: set MODE and URL. For dual-display, set MODE2/URL2/OUTPUT2.
EOF
    emit_config_line GUI_USER "${GUI_USER:-}"
    emit_config_line MODE     "${MODE:-chrome}"
    emit_config_line URL      "${URL:-$DEFAULT_URL}"
    emit_config_line OUTPUT   "${OUTPUT:-}"
    emit_config_line MODE2    "${MODE2:-}"
    emit_config_line URL2     "${URL2:-}"
    emit_config_line OUTPUT2  "${OUTPUT2:-}"
    cat <<'EOF'
# Optional tuning: run `kiosk-monitor.sh --reconfig` to persist the full list of options.
# Docs: https://github.com/extremeshok/kiosk-monitor#readme
EOF
  } > "$tmp"
  install -m 0644 "$tmp" "$target"
  rm -f "$tmp"
}

set_or_append_conf_value() {
  local key=$1 value=$2 target=$3
  local escaped; escaped=$(escape_config_value "$value")
  if grep -q "^${key}=" "$target" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=\"${escaped}\"|" "$target"
  else
    printf '%s="%s"\n' "$key" "$escaped" >> "$target"
  fi
}

ensure_config_file() {
  local url_override=$1 gui_override=$2 mode_override=$3
  local output_override=$4 mode2_override=$5 url2_override=$6 output2_override=$7
  local target="$CONFIG_FILE"
  mkdir -p "$CONFIG_DIR"
  [ -f "$target" ] || render_config_file
  [ -n "$url_override" ]     && set_or_append_conf_value URL      "$url_override"     "$target"
  [ -n "$gui_override" ]     && set_or_append_conf_value GUI_USER "$gui_override"     "$target"
  [ -n "$mode_override" ]    && set_or_append_conf_value MODE     "$mode_override"    "$target"
  [ -n "$output_override" ]  && set_or_append_conf_value OUTPUT   "$output_override"  "$target"
  [ -n "$mode2_override" ]   && set_or_append_conf_value MODE2    "$mode2_override"   "$target"
  [ -n "$url2_override" ]    && set_or_append_conf_value URL2     "$url2_override"    "$target"
  [ -n "$output2_override" ] && set_or_append_conf_value OUTPUT2  "$output2_override" "$target"
  return 0
}

ensure_apt_dependencies() {
  # Installs any missing runtime prerequisites via apt-get. Safe to call more
  # than once; skips work when everything is present. Invoked from install/
  # update paths and can be disabled with --skip-apt.
  require_root
  command -v apt-get >/dev/null 2>&1 || {
    echo "apt-get not found; skipping dependency install." >&2
    return 0
  }

  # cmd → package (apt package that provides the command)
  declare -A pkg_for=(
    [curl]=curl
    [grim]=grim
    [wlr-randr]=wlr-randr
    [python3]=python3
    [whiptail]=whiptail
    [flock]=util-linux
    [sha256sum]=coreutils
    [xwd]=x11-apps
    [xset]=x11-xserver-utils
    [xrandr]=x11-xserver-utils
  )

  # chromium / vlc: any of several commands satisfies the dep; install
  # package only if none of them are present.
  local bin has_chromium="no" has_vlc="no"
  for bin in chromium chromium-browser google-chrome; do
    command -v "$bin" >/dev/null 2>&1 && { has_chromium="yes"; break; }
  done
  [ "$has_chromium" = "no" ] && pkg_for[chromium]=chromium

  for bin in vlc cvlc; do
    command -v "$bin" >/dev/null 2>&1 && { has_vlc="yes"; break; }
  done
  [ "$has_vlc" = "no" ] && pkg_for[vlc]=vlc

  local -a to_install=()
  local cmd pkg
  for cmd in "${!pkg_for[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 && continue
    pkg="${pkg_for[$cmd]}"
    case " ${to_install[*]:-} " in *" $pkg "*) ;; *) to_install+=( "$pkg" ) ;; esac
  done

  if [ "${#to_install[@]}" -eq 0 ]; then
    echo "All required packages are already installed."
    return 0
  fi

  echo "Installing missing dependencies via apt: ${to_install[*]}"
  # refresh apt index if it's older than 24 hours
  local cache_age=99999
  if [ -f /var/cache/apt/pkgcache.bin ]; then
    cache_age=$(( $(date +%s) - $(stat -c %Y /var/cache/apt/pkgcache.bin 2>/dev/null || echo 0) ))
  fi
  if [ "$cache_age" -gt 86400 ]; then
    echo "Refreshing apt index…"
    apt-get update -qq || echo "Warning: apt-get update failed; continuing with cached index." >&2
  fi
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${to_install[@]}"; then
    echo "Error: apt-get install failed for: ${to_install[*]}" >&2
    echo "Install them manually and re-run." >&2
    return 1
  fi
  echo "Dependency install complete."
  return 0
}

install_self() {
  require_root
  need_cmd systemctl; need_cmd install

  local url_override="" gui_override="" mode_override=""
  local output_override="" mode2_override="" url2_override="" output2_override=""
  local autostart="yes" skip_apt="no"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --url)        shift; url_override="${1:-}";      [ -n "$url_override" ]     || { echo 'Error: --url requires a value' >&2; exit 1; } ;;
      --url2)       shift; url2_override="${1:-}";     [ -n "$url2_override" ]    || { echo 'Error: --url2 requires a value' >&2; exit 1; } ;;
      --mode)       shift; mode_override="${1:-}";     [ -n "$mode_override" ]    || { echo 'Error: --mode requires a value' >&2; exit 1; }
                    mode_override=$(printf '%s' "$mode_override" | tr '[:upper:]' '[:lower:]')
                    case "$mode_override" in chromium|chrome) mode_override="chrome" ;; esac ;;
      --mode2)      shift; mode2_override="${1:-}";    [ -n "$mode2_override" ]   || { echo 'Error: --mode2 requires a value' >&2; exit 1; }
                    mode2_override=$(printf '%s' "$mode2_override" | tr '[:upper:]' '[:lower:]')
                    case "$mode2_override" in chromium|chrome) mode2_override="chrome" ;; esac ;;
      --output)     shift; output_override="${1:-}";   [ -n "$output_override" ]  || { echo 'Error: --output requires a value' >&2; exit 1; } ;;
      --output2)    shift; output2_override="${1:-}";  [ -n "$output2_override" ] || { echo 'Error: --output2 requires a value' >&2; exit 1; } ;;
      --browser)    shift; mode_override="${1:-}";     # legacy alias
                    case "$mode_override" in chromium|chrome) mode_override="chrome" ;; vlc|VLC) mode_override="vlc" ;; esac ;;
      --gui-user|--user) shift; gui_override="${1:-}"; [ -n "$gui_override" ]     || { echo 'Error: --gui-user requires a value' >&2; exit 1; } ;;
      --no-start)   autostart="no" ;;
      --skip-apt)   skip_apt="yes" ;;
      --base-url)   shift; BASE_URL="${1:-}";          [ -n "$BASE_URL" ]         || { echo 'Error: --base-url requires a value' >&2; exit 1; } ;;
      *) printf 'Error: unknown install option %s\n' "$1" >&2; usage; exit 1 ;;
    esac
    shift
  done

  if [ "$skip_apt" = "no" ]; then
    ensure_apt_dependencies || exit 1
  fi

  local effective_gui
  if [ -n "$gui_override" ]; then
    GUI_USER="$gui_override"; effective_gui="$gui_override"
  else
    auto_detect_gui_user || { echo 'Unable to detect desktop user; pass --gui-user' >&2; exit 1; }
    effective_gui="$GUI_USER"
  fi
  local gui_uid; gui_uid=$(id -u "$effective_gui")
  local runtime_dir="/run/user/$gui_uid"
  local wayland_display=""
  if [ -d "$runtime_dir" ]; then
    local socket
    for socket in "$runtime_dir"/wayland-*; do
      [ -S "$socket" ] || continue
      case "$socket" in *.lock) continue ;; esac
      wayland_display=$(basename "$socket"); break
    done
  fi
  [ -z "$wayland_display" ] && wayland_display="wayland-0"

  local resolved_script script_dir
  resolved_script=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
  script_dir=$(dirname "$resolved_script")

  mkdir -p "$INSTALL_DIR"
  ensure_script_installed "$resolved_script" "$INSTALL_DIR/kiosk-monitor"
  install_bash_completion "$script_dir"

  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_DIR/kiosk-monitor.conf.sample" ] && [ -f "$script_dir/kiosk-monitor.conf.sample" ]; then
    install -m 0644 "$script_dir/kiosk-monitor.conf.sample" "$CONFIG_DIR/kiosk-monitor.conf.sample"
  fi
  ensure_config_file "$url_override" "$gui_override" "$mode_override" \
                     "$output_override" "$mode2_override" "$url2_override" "$output2_override"

  local service_dependency=""
  local dep
  if dep=$(tailscaled_dependency_unit); then service_dependency="$dep"; fi
  write_service_unit "$effective_gui" "$runtime_dir" "$wayland_display" "$SERVICE_PATH" "$service_dependency"
  systemctl daemon-reload
  if [ "$autostart" = "yes" ]; then
    systemctl enable --now kiosk-monitor.service
    echo 'kiosk-monitor installed and started.'
  else
    systemctl enable kiosk-monitor.service
    echo 'kiosk-monitor installed (service enabled but not started).'
  fi
}

download_component() {
  local source=$1 destination=$2 mode=${3:-0644} tmp
  need_cmd curl; need_cmd install
  tmp=$(mktemp)
  if ! curl -fsSL --connect-timeout 10 --max-time 60 "${BASE_URL%/}/$source" -o "$tmp"; then
    printf 'Error: failed to download %s from %s\n' "$source" "$BASE_URL" >&2
    rm -f "$tmp"; return 1
  fi
  case "$source" in
    *.sh)
      if ! head -1 "$tmp" | grep -q '^#!'; then
        echo "Error: downloaded $source is not a shell script (bad shebang)" >&2
        rm -f "$tmp"; return 1
      fi
      ;;
  esac
  if [ ! -s "$tmp" ]; then
    echo "Error: downloaded $source is empty" >&2
    rm -f "$tmp"; return 1
  fi
  install -m "$mode" "$tmp" "$destination"
  rm -f "$tmp"
  return 0
}

fetch_remote_version() {
  need_cmd curl
  local tmp ver=""
  tmp=$(mktemp)
  if curl -fsSL --connect-timeout 10 --max-time 30 "${BASE_URL%/}/kiosk-monitor.sh" -o "$tmp" 2>/dev/null; then
    ver=$(grep -m1 '^SCRIPT_VERSION=' "$tmp" | sed -E 's/^SCRIPT_VERSION="?([^"]+)"?.*$/\1/')
  fi
  rm -f "$tmp"
  printf '%s\n' "$ver"
}

update_self() {
  require_root
  need_cmd systemctl; need_cmd install
  local gui_override="" mode_override="" suppress_restart="no"
  local source_mode="remote" check_only="no" force_install="no" skip_apt="no"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --gui-user|--user) shift; gui_override="${1:-}"; [ -n "$gui_override" ] || { echo 'Error: --gui-user requires a value' >&2; exit 1; } ;;
      --mode)       shift; mode_override="${1:-}"; mode_override=$(printf '%s' "$mode_override" | tr '[:upper:]' '[:lower:]')
                    case "$mode_override" in chromium|chrome) mode_override="chrome" ;; esac ;;
      --browser)    shift; mode_override="${1:-}"; case "$mode_override" in chromium|chrome) mode_override="chrome" ;; vlc|VLC) mode_override="vlc" ;; esac ;;
      --no-restart) suppress_restart="yes" ;;
      --local)      source_mode="local" ;;
      --check)      check_only="yes" ;;
      --force)      force_install="yes" ;;
      --skip-apt)   skip_apt="yes" ;;
      --base-url)   shift; BASE_URL="${1:-}"; [ -n "$BASE_URL" ] || { echo 'Error: --base-url requires a value' >&2; exit 1; } ;;
      *) printf 'Error: unknown update option %s\n' "$1" >&2; usage; exit 1 ;;
    esac
    shift
  done

  # --- remote version check ---
  local remote_ver=""
  if [ "$source_mode" = "remote" ] || [ "$check_only" = "yes" ]; then
    echo "Checking $BASE_URL for newer kiosk-monitor…"
    remote_ver=$(fetch_remote_version 2>/dev/null) || true
    if [ -n "$remote_ver" ]; then
      printf 'Installed : %s\n' "$SCRIPT_VERSION"
      printf 'Remote    : %s\n' "$remote_ver"
    else
      printf 'Installed : %s\n' "$SCRIPT_VERSION"
      printf 'Remote    : (unknown — fetch failed)\n'
      if [ "$check_only" = "yes" ]; then exit 1; fi
      if [ "$source_mode" = "remote" ] && [ "$force_install" != "yes" ]; then
        echo 'Use --force to attempt install anyway, or --local to install from this file.' >&2
        exit 1
      fi
    fi
    if [ "$check_only" = "yes" ]; then
      if [ -z "$remote_ver" ] || [ "$remote_ver" = "$SCRIPT_VERSION" ]; then
        echo 'Up to date.'
      else
        echo 'Update available.'
      fi
      exit 0
    fi
    if [ "$source_mode" = "remote" ] && [ -n "$remote_ver" ] \
       && [ "$remote_ver" = "$SCRIPT_VERSION" ] && [ "$force_install" != "yes" ]; then
      echo 'Already at the latest version. Use --force to reinstall.'
      exit 0
    fi
  fi

  if [ "$skip_apt" = "no" ]; then
    ensure_apt_dependencies || exit 1
  fi

  local was_active="no"
  systemctl is-active --quiet kiosk-monitor.service && was_active="yes"

  local effective_gui
  if [ -n "$gui_override" ]; then
    GUI_USER="$gui_override"; effective_gui="$gui_override"
  else
    auto_detect_gui_user || { echo 'Unable to detect desktop user; pass --gui-user' >&2; exit 1; }
    effective_gui="$GUI_USER"
  fi
  local gui_uid; gui_uid=$(id -u "$effective_gui")
  local runtime_dir="/run/user/$gui_uid"
  local wayland_display=""
  if [ -d "$runtime_dir" ]; then
    local socket
    for socket in "$runtime_dir"/wayland-*; do
      [ -S "$socket" ] || continue
      case "$socket" in *.lock) continue ;; esac
      wayland_display=$(basename "$socket"); break
    done
  fi
  [ -z "$wayland_display" ] && wayland_display="wayland-0"

  mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

  if [ "$source_mode" = "remote" ]; then
    echo "Downloading kiosk-monitor.sh from $BASE_URL…"
    download_component kiosk-monitor.sh         "$INSTALL_DIR/kiosk-monitor"            0755 || exit 1
    rm -f "$INSTALL_DIR/kiosk-monitor.sh"
    echo "Downloading kiosk-monitor.conf.sample…"
    download_component kiosk-monitor.conf.sample "$CONFIG_DIR/kiosk-monitor.conf.sample" 0644 || true
    # Use an empty script_dir so install_bash_completion falls through to
    # the remote download path.
    install_bash_completion /nonexistent
  else
    local resolved_script script_dir
    resolved_script=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
    script_dir=$(dirname "$resolved_script")
    ensure_script_installed "$resolved_script" "$INSTALL_DIR/kiosk-monitor"
    install_bash_completion "$script_dir"
    if [ -f "$script_dir/kiosk-monitor.conf.sample" ]; then
      install -m 0644 "$script_dir/kiosk-monitor.conf.sample" "$CONFIG_DIR/kiosk-monitor.conf.sample"
    fi
  fi

  [ -n "$mode_override" ] && ensure_config_file "" "" "$mode_override" "" "" "" ""

  local service_dependency=""
  local dep
  if dep=$(tailscaled_dependency_unit); then service_dependency="$dep"; fi
  write_service_unit "$effective_gui" "$runtime_dir" "$wayland_display" "$SERVICE_PATH" "$service_dependency"
  systemctl daemon-reload

  local new_ver
  new_ver=$("$INSTALL_DIR/kiosk-monitor" --version 2>/dev/null || echo "$SCRIPT_VERSION")
  if [ "$was_active" = "yes" ] && [ "$suppress_restart" = "no" ]; then
    systemctl restart kiosk-monitor.service
    echo "kiosk-monitor updated to $new_ver and restarted."
  else
    echo "kiosk-monitor updated to $new_ver."
  fi
}

remove_self() {
  require_root; need_cmd systemctl
  local purge="no"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --purge) purge="yes" ;;
      *) printf 'Error: unknown remove option %s\n' "$1" >&2; usage; exit 1 ;;
    esac
    shift
  done
  if systemctl list-unit-files --no-legend | awk '{print $1}' | grep -qx 'kiosk-monitor.service'; then
    systemctl stop kiosk-monitor.service 2>/dev/null || true
    systemctl disable kiosk-monitor.service 2>/dev/null || true
  fi
  rm -f "$SERVICE_PATH"
  rm -f "$INSTALL_DIR/kiosk-monitor.sh" "$INSTALL_DIR/kiosk-monitor"
  rm -f /etc/bash_completion.d/kiosk-monitor
  if [ "$purge" = "yes" ]; then
    rm -f "$CONFIG_FILE"
    [ -d "$CONFIG_DIR" ] && rmdir "$CONFIG_DIR" 2>/dev/null || true
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

# ----------------------------------------------------------------------
# Interactive TUI (whiptail)
# ----------------------------------------------------------------------
_wt_run() {
  # Runs whiptail, isolating its stdout (menu results) from stderr (UI).
  # Returns whiptail's exit code; caller inspects $? to detect Cancel/ESC.
  local rc
  set +e
  "$@" 3>&1 1>&2 2>&3
  rc=$?
  set -e
  return $rc
}

_wt_menu() {
  # title, prompt, height, width, list-height, then tag/description pairs
  local title=$1 prompt=$2 h=$3 w=$4 lh=$5
  shift 5
  _wt_run whiptail --title "$title" --menu "$prompt" "$h" "$w" "$lh" "$@"
}

_wt_input() {
  local title=$1 prompt=$2 default=$3
  _wt_run whiptail --title "$title" --inputbox "$prompt" 10 78 "$default"
}

_wt_yesno() {
  local title=$1 prompt=$2 default=${3:-yes}
  local flag=""
  [ "$default" = "no" ] && flag="--defaultno"
  set +e
  whiptail --title "$title" --yesno $flag "$prompt" 10 70
  local rc=$?
  set -e
  return $rc
}

# ======================================================================
# TUI state (script-scope so submenus can mutate without juggling globals).
# ======================================================================
TUI_MODE=""; TUI_URL=""; TUI_OUTPUT=""; TUI_RES=""; TUI_ROT=""
TUI_MODE2=""; TUI_URL2=""; TUI_OUTPUT2=""; TUI_RES2=""; TUI_ROT2=""
TUI_FRIGATE_DARK=""; TUI_FRIGATE_THEME=""; TUI_FRIGATE_AUTOFILL=""
TUI_FRIGATE_WIDTH=""; TUI_FRIGATE_HEIGHT=""; TUI_FRIGATE_MARGIN=""
TUI_GUI_USER=""
TUI_HEALTH_INTERVAL=""; TUI_SCREEN_DELAY=""; TUI_STALL_RETRIES=""
TUI_VLC_STALL_RETRIES=""; TUI_HEALTH_RETRIES=""
TUI_MIN_UPTIME=""; TUI_SESSION_WAIT=""; TUI_WAYLAND_WAIT=""
TUI_LOG_MAX_BYTES=""; TUI_LOG_ROTATE_KEEP=""
TUI_PROFILE_TMPFS=""; TUI_PROFILE_SYNC_BACK=""; TUI_PREWARM=""
TUI_VLC_LOOP=""; TUI_VLC_NO_AUDIO=""; TUI_VLC_NETWORK_CACHING=""
TUI_DIRTY="no"
declare -a TUI_OUTPUT_TAGS=()

_tui_load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
  TUI_MODE="${MODE:-chrome}";        TUI_URL="${URL:-}";        TUI_OUTPUT="${OUTPUT:-}"
  TUI_RES="${FORCE_RESOLUTION:-}";   TUI_ROT="${FORCE_ROTATION:-}"
  TUI_MODE2="${MODE2:-}";            TUI_URL2="${URL2:-}";      TUI_OUTPUT2="${OUTPUT2:-}"
  TUI_RES2="${FORCE_RESOLUTION_2:-}"; TUI_ROT2="${FORCE_ROTATION_2:-}"
  TUI_FRIGATE_DARK="${FRIGATE_DARK_MODE:-}"
  TUI_FRIGATE_THEME="${FRIGATE_THEME:-}"
  TUI_FRIGATE_AUTOFILL="${FRIGATE_BIRDSEYE_AUTO_FILL:-false}"
  TUI_FRIGATE_WIDTH="${FRIGATE_BIRDSEYE_WIDTH:-}"
  TUI_FRIGATE_HEIGHT="${FRIGATE_BIRDSEYE_HEIGHT:-}"
  TUI_FRIGATE_MARGIN="${FRIGATE_BIRDSEYE_MARGIN:-80}"
  TUI_GUI_USER="${GUI_USER:-}"
  TUI_HEALTH_INTERVAL="${HEALTH_INTERVAL:-30}"
  TUI_SCREEN_DELAY="${SCREEN_DELAY:-120}"
  TUI_STALL_RETRIES="${STALL_RETRIES:-3}"
  TUI_VLC_STALL_RETRIES="${VLC_STALL_RETRIES:-6}"
  TUI_HEALTH_RETRIES="${HEALTH_RETRIES:-6}"
  TUI_MIN_UPTIME="${MIN_UPTIME_BEFORE_START:-60}"
  TUI_SESSION_WAIT="${GUI_SESSION_WAIT_TIMEOUT:-300}"
  TUI_WAYLAND_WAIT="${WAYLAND_READY_TIMEOUT:-300}"
  TUI_LOG_MAX_BYTES="${LOG_MAX_BYTES:-2097152}"
  TUI_LOG_ROTATE_KEEP="${LOG_ROTATE_KEEP:-1}"
  TUI_PROFILE_TMPFS="${PROFILE_TMPFS:-false}"
  TUI_PROFILE_SYNC_BACK="${PROFILE_SYNC_BACK:-false}"
  TUI_PREWARM="${PREWARM_ENABLED:-true}"
  TUI_VLC_LOOP="${VLC_LOOP:-true}"
  TUI_VLC_NO_AUDIO="${VLC_NO_AUDIO:-false}"
  TUI_VLC_NETWORK_CACHING="${VLC_NETWORK_CACHING:-}"
  TUI_DIRTY="no"
}

_tui_probe_outputs() {
  if [ -z "${GUI_USER:-}" ] || [ "$GUI_USER" = "root" ]; then
    auto_detect_gui_user 2>/dev/null || true
  fi
  if [ -n "${GUI_USER:-}" ] && [ "$GUI_USER" != "root" ]; then
    GUI_UID=$(id -u "$GUI_USER" 2>/dev/null || echo 0)
    : "${XDG_RUNTIME_DIR:=/run/user/$GUI_UID}"
    export XDG_RUNTIME_DIR
    if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
      local sock
      for sock in "$XDG_RUNTIME_DIR"/wayland-*; do
        case "$sock" in *.lock) continue ;; esac
        [ -S "$sock" ] && { WAYLAND_DISPLAY=$(basename "$sock"); export WAYLAND_DISPLAY; break; }
      done
    fi
    refresh_outputs 2>/dev/null || true
  fi
  TUI_OUTPUT_TAGS=( "" "(auto — kiosk-monitor picks)" )
  local name
  for name in "${OUTPUTS_NAMES[@]}"; do
    TUI_OUTPUT_TAGS+=( "$name" "${OUTPUT_GEOMETRY[$name]:-?}" )
  done
}

_tui_bool_toggle() {
  # $1 current value, echoes the flipped value
  case "$1" in true) echo false ;; *) echo true ;; esac
}

_tui_preview_value() {
  # Render a value with "(none)" / "(auto)" substitutes for empty.
  local v="$1" empty="${2:-(none)}"
  if [ -z "$v" ]; then echo "$empty"; else echo "$v"; fi
}

_tui_mode_picker() {
  # args: title, current-value. echoes chosen value, or exit on cancel.
  _wt_menu "$1" "Choose launch mode" 11 60 2 \
    "chrome" "Fullscreen Chromium kiosk" \
    "vlc"    "Fullscreen VLC video player"
}

_tui_rotation_picker() {
  # args: title, current. echoes chosen.
  _wt_menu "$1" "Force the output orientation." 17 60 9 \
    ""            "Do not override" \
    "normal"      "0° (no rotation)" \
    "90"          "90° clockwise" \
    "180"         "180°" \
    "270"         "270° clockwise" \
    "flipped"     "mirrored" \
    "flipped-90"  "mirrored + 90°" \
    "flipped-180" "mirrored + 180°" \
    "flipped-270" "mirrored + 270°"
}

_tui_output_picker() {
  if [ "${#TUI_OUTPUT_TAGS[@]}" -lt 2 ]; then
    _wt_input "$1" "Output name (e.g. HDMI-A-1), blank = auto:" "$2"
  else
    _wt_menu "$1" "Which display?" 16 70 8 "${TUI_OUTPUT_TAGS[@]}"
  fi
}

_tui_edit_instance() {
  # args: id (1 or 2), vref_mode, vref_url, vref_output, vref_res, vref_rot
  local id=$1
  # shellcheck disable=SC2034  # referenced via nameref
  local -n m=$2 u=$3 o=$4 r=$5 rot=$6
  while true; do
    local m_disp; m_disp=$(_tui_preview_value "$m" "(not set)")
    local u_disp; u_disp=$(_tui_preview_value "$u" "(not set)")
    local o_disp; o_disp=$(_tui_preview_value "$o" "(auto)")
    local r_disp; r_disp=$(_tui_preview_value "$r" "(compositor default)")
    local rot_disp; rot_disp=$(_tui_preview_value "$rot" "(compositor default)")
    local choice
    choice=$(_wt_menu "Instance $id" "Edit instance-$id settings. Pick a field to change, or Back to return." 17 72 7 \
      "mode"       "$m_disp" \
      "url"        "$u_disp" \
      "output"     "$o_disp" \
      "resolution" "$r_disp" \
      "rotation"   "$rot_disp" \
      "back"       "Return to the main menu") || return 0
    case "$choice" in
      mode)
        local v; v=$(_tui_mode_picker "Instance $id — mode") || continue
        m="$v"; TUI_DIRTY="yes" ;;
      url)
        local v; v=$(_wt_input "Instance $id — URL" "URL for chrome, or stream path for VLC:" "$u") || continue
        u="$v"; TUI_DIRTY="yes" ;;
      output)
        local v; v=$(_tui_output_picker "Instance $id — output" "$o") || continue
        o="$v"; TUI_DIRTY="yes" ;;
      resolution)
        local v; v=$(_wt_input "Instance $id — force resolution" \
          "WxH or WxH@Hz (blank = leave alone):" "$r") || continue
        r="$v"; TUI_DIRTY="yes" ;;
      rotation)
        local v; v=$(_tui_rotation_picker "Instance $id — force rotation") || continue
        rot="$v"; TUI_DIRTY="yes" ;;
      back) return 0 ;;
    esac
  done
}

_tui_edit_instance2() {
  while true; do
    local enabled_label
    if [ -n "$TUI_MODE2" ]; then
      enabled_label="enabled ($TUI_MODE2 → $(_tui_preview_value "$TUI_URL2" "not set"))"
    else
      enabled_label="disabled"
    fi
    local choice
    choice=$(_wt_menu "Instance 2" "Second display configuration." 13 68 4 \
      "toggle" "Enable / disable instance 2 — $enabled_label" \
      "edit"   "Edit mode / URL / output / resolution / rotation" \
      "back"   "Return to the main menu" \
      "help"   "About dual-display (experimental)") || return 0
    case "$choice" in
      toggle)
        if [ -n "$TUI_MODE2" ]; then
          TUI_MODE2=""; TUI_URL2=""; TUI_OUTPUT2=""; TUI_RES2=""; TUI_ROT2=""
        else
          TUI_MODE2="chrome"
          [ -z "$TUI_URL2" ] && TUI_URL2="$TUI_URL"
        fi
        TUI_DIRTY="yes" ;;
      edit)
        if [ -z "$TUI_MODE2" ]; then
          whiptail --title "Instance 2" --msgbox "Enable instance 2 first." 10 50
          continue
        fi
        _tui_edit_instance 2 TUI_MODE2 TUI_URL2 TUI_OUTPUT2 TUI_RES2 TUI_ROT2 ;;
      help)
        whiptail --title "Instance 2 (experimental)" --scrolltext --msgbox \
"Running two instances side-by-side on a Pi is supported for Chromium
but VLC routing on Wayland is still flaky. labwc window rules are
auto-generated in ~/.config/labwc/rc.xml to route each window to its
configured output. Single-instance setups (Instance 2 disabled) leave
the compositor config untouched." 16 70 ;;
      back) return 0 ;;
    esac
  done
}

_tui_edit_frigate() {
  while true; do
    local size_disp
    if [ -n "$TUI_FRIGATE_WIDTH" ] || [ -n "$TUI_FRIGATE_HEIGHT" ]; then
      size_disp="$(_tui_preview_value "$TUI_FRIGATE_WIDTH" auto)x$(_tui_preview_value "$TUI_FRIGATE_HEIGHT" auto) (fixed)"
    else
      size_disp="auto (viewport minus ${TUI_FRIGATE_MARGIN}px margin)"
    fi
    local choice
    choice=$(_wt_menu "Frigate helper" \
"Tweaks applied by the injected Chrome extension when the URL points at Frigate." 18 72 7 \
      "dark"     "Dark mode: $(_tui_preview_value "$TUI_FRIGATE_DARK" smart-default)" \
      "theme"    "Colour theme: $(_tui_preview_value "$TUI_FRIGATE_THEME" smart-default)" \
      "autofill" "Birdseye auto-fill: $TUI_FRIGATE_AUTOFILL" \
      "size"     "Birdseye grid size: $size_disp" \
      "margin"   "Auto-size margin: ${TUI_FRIGATE_MARGIN}px" \
      "back"     "Return to the main menu") || return 0
    case "$choice" in
      dark)
        local v; v=$(_wt_menu "Dark mode" "Force Frigate's theme." 12 60 4 \
          ""      "Smart default (based on URL)" \
          "None"  "Explicitly leave unchanged" \
          "Light" "Force light theme" \
          "Dark"  "Force dark theme") || continue
        TUI_FRIGATE_DARK="$v"; TUI_DIRTY="yes" ;;
      theme)
        local v; v=$(_wt_menu "Colour theme" "Force Frigate's colour theme." 17 60 8 \
          ""              "Smart default (based on URL)" \
          "None"          "Explicitly leave unchanged" \
          "Default"       "Frigate default" \
          "Blue"          "Blue accent" \
          "Green"         "Green accent" \
          "Nord"          "Nord palette" \
          "Red"           "Red accent" \
          "High Contrast" "High-contrast theme") || continue
        TUI_FRIGATE_THEME="$v"; TUI_DIRTY="yes" ;;
      autofill)
        TUI_FRIGATE_AUTOFILL=$(_tui_bool_toggle "$TUI_FRIGATE_AUTOFILL")
        TUI_DIRTY="yes" ;;
      size)
        local w h
        w=$(_wt_input "Birdseye width" "Grid width in pixels (blank = auto from viewport):" "$TUI_FRIGATE_WIDTH") || continue
        h=$(_wt_input "Birdseye height" "Grid height in pixels (blank = auto from viewport):" "$TUI_FRIGATE_HEIGHT") || continue
        TUI_FRIGATE_WIDTH="$w"; TUI_FRIGATE_HEIGHT="$h"; TUI_DIRTY="yes" ;;
      margin)
        local v; v=$(_wt_input "Birdseye margin" "Pixels trimmed from each axis when auto-sizing:" "$TUI_FRIGATE_MARGIN") || continue
        TUI_FRIGATE_MARGIN="$v"; TUI_DIRTY="yes" ;;
      back) return 0 ;;
    esac
  done
}

_tui_edit_timing() {
  while true; do
    local choice
    choice=$(_wt_menu "Timing & restart" "Watchdog cadence and restart thresholds." 20 72 11 \
      "health"      "Health-check interval: ${TUI_HEALTH_INTERVAL}s" \
      "screen"      "Screen-freeze check delay: ${TUI_SCREEN_DELAY}s" \
      "stall"       "Screen-stall retries (chrome): ${TUI_STALL_RETRIES}" \
      "vlcstall"    "Screen-stall retries (vlc):    ${TUI_VLC_STALL_RETRIES}" \
      "fail"        "HTTP health-fail retries: ${TUI_HEALTH_RETRIES}" \
      "uptime"      "Minimum system uptime before start: ${TUI_MIN_UPTIME}s" \
      "session"     "GUI session wait timeout: ${TUI_SESSION_WAIT}s" \
      "wayland"     "Wayland/labwc ready timeout: ${TUI_WAYLAND_WAIT}s" \
      "back"        "Return to the main menu") || return 0
    case "$choice" in
      health)   TUI_HEALTH_INTERVAL=$(_wt_input "Health interval (seconds)" "Seconds between watchdog ticks:" "$TUI_HEALTH_INTERVAL") || continue; TUI_DIRTY="yes" ;;
      screen)   TUI_SCREEN_DELAY=$(_wt_input "Screen delay (seconds)" "Grace period before freeze detection kicks in:" "$TUI_SCREEN_DELAY") || continue; TUI_DIRTY="yes" ;;
      stall)    TUI_STALL_RETRIES=$(_wt_input "Chrome stall retries" "Identical-frame hashes before restarting chrome:" "$TUI_STALL_RETRIES") || continue; TUI_DIRTY="yes" ;;
      vlcstall) TUI_VLC_STALL_RETRIES=$(_wt_input "VLC stall retries" "Identical-frame hashes before restarting VLC:" "$TUI_VLC_STALL_RETRIES") || continue; TUI_DIRTY="yes" ;;
      fail)     TUI_HEALTH_RETRIES=$(_wt_input "Health retries" "Failed HTTP probes before restarting:" "$TUI_HEALTH_RETRIES") || continue; TUI_DIRTY="yes" ;;
      uptime)   TUI_MIN_UPTIME=$(_wt_input "Min uptime (seconds)" "Wait until system uptime \u2265 N seconds:" "$TUI_MIN_UPTIME") || continue; TUI_DIRTY="yes" ;;
      session)  TUI_SESSION_WAIT=$(_wt_input "Session wait timeout" "Seconds to wait for a loginctl session:" "$TUI_SESSION_WAIT") || continue; TUI_DIRTY="yes" ;;
      wayland)  TUI_WAYLAND_WAIT=$(_wt_input "Wayland wait timeout" "Seconds to wait for labwc + wayland socket:" "$TUI_WAYLAND_WAIT") || continue; TUI_DIRTY="yes" ;;
      back) return 0 ;;
    esac
  done
}

_tui_edit_profile_logs() {
  while true; do
    local choice
    choice=$(_wt_menu "Profile & logging" "Log rotation, Chromium profile, VLC options, prewarm." 18 72 9 \
      "logmax"    "Log max bytes: $TUI_LOG_MAX_BYTES" \
      "logkeep"   "Rotate keep (.1 file): $TUI_LOG_ROTATE_KEEP" \
      "tmpfs"     "Profile in tmpfs: $TUI_PROFILE_TMPFS" \
      "syncback"  "Profile sync back on exit: $TUI_PROFILE_SYNC_BACK" \
      "prewarm"   "Prewarm binaries/profile: $TUI_PREWARM" \
      "vlcloop"   "VLC --loop: $TUI_VLC_LOOP" \
      "vlcmute"   "VLC --no-audio: $TUI_VLC_NO_AUDIO" \
      "vlccache"  "VLC network-caching (ms): $(_tui_preview_value "$TUI_VLC_NETWORK_CACHING" default)" \
      "back"      "Return to the main menu") || return 0
    case "$choice" in
      logmax)   TUI_LOG_MAX_BYTES=$(_wt_input "Log max bytes" "Truncate /dev/shm/kiosk.log once it exceeds N bytes:" "$TUI_LOG_MAX_BYTES") || continue; TUI_DIRTY="yes" ;;
      logkeep)  TUI_LOG_ROTATE_KEEP=$(_wt_input "Log rotate keep" "Keep N previous copies (.1):" "$TUI_LOG_ROTATE_KEEP") || continue; TUI_DIRTY="yes" ;;
      tmpfs)    TUI_PROFILE_TMPFS=$(_tui_bool_toggle "$TUI_PROFILE_TMPFS"); TUI_DIRTY="yes" ;;
      syncback) TUI_PROFILE_SYNC_BACK=$(_tui_bool_toggle "$TUI_PROFILE_SYNC_BACK"); TUI_DIRTY="yes" ;;
      prewarm)  TUI_PREWARM=$(_tui_bool_toggle "$TUI_PREWARM"); TUI_DIRTY="yes" ;;
      vlcloop)  TUI_VLC_LOOP=$(_tui_bool_toggle "$TUI_VLC_LOOP"); TUI_DIRTY="yes" ;;
      vlcmute)  TUI_VLC_NO_AUDIO=$(_tui_bool_toggle "$TUI_VLC_NO_AUDIO"); TUI_DIRTY="yes" ;;
      vlccache) TUI_VLC_NETWORK_CACHING=$(_wt_input "VLC network caching" "Milliseconds (blank = VLC default; raise for flaky RTSP):" "$TUI_VLC_NETWORK_CACHING") || continue; TUI_DIRTY="yes" ;;
      back) return 0 ;;
    esac
  done
}

_tui_edit_in_editor() {
  local editor=${EDITOR:-nano}
  command -v "$editor" >/dev/null 2>&1 || editor="nano"
  command -v "$editor" >/dev/null 2>&1 || editor="vi"
  whiptail --title "Edit config" --msgbox \
"About to open $CONFIG_FILE in $editor.
Save and exit to return here — values will be re-read." 11 70
  clear
  "$editor" "$CONFIG_FILE"
  _tui_load_config
}

_tui_write_all() {
  mkdir -p "$CONFIG_DIR"
  [ -f "$CONFIG_FILE" ] || render_config_file
  local cf=$CONFIG_FILE
  set_or_append_conf_value MODE                        "$TUI_MODE"                 "$cf"
  set_or_append_conf_value URL                         "$TUI_URL"                  "$cf"
  set_or_append_conf_value OUTPUT                      "$TUI_OUTPUT"               "$cf"
  set_or_append_conf_value FORCE_RESOLUTION            "$TUI_RES"                  "$cf"
  set_or_append_conf_value FORCE_ROTATION              "$TUI_ROT"                  "$cf"
  set_or_append_conf_value MODE2                       "$TUI_MODE2"                "$cf"
  set_or_append_conf_value URL2                        "$TUI_URL2"                 "$cf"
  set_or_append_conf_value OUTPUT2                     "$TUI_OUTPUT2"              "$cf"
  set_or_append_conf_value FORCE_RESOLUTION_2          "$TUI_RES2"                 "$cf"
  set_or_append_conf_value FORCE_ROTATION_2            "$TUI_ROT2"                 "$cf"
  set_or_append_conf_value FRIGATE_DARK_MODE           "$TUI_FRIGATE_DARK"         "$cf"
  set_or_append_conf_value FRIGATE_THEME               "$TUI_FRIGATE_THEME"        "$cf"
  set_or_append_conf_value FRIGATE_BIRDSEYE_AUTO_FILL  "$TUI_FRIGATE_AUTOFILL"     "$cf"
  set_or_append_conf_value FRIGATE_BIRDSEYE_WIDTH      "$TUI_FRIGATE_WIDTH"        "$cf"
  set_or_append_conf_value FRIGATE_BIRDSEYE_HEIGHT     "$TUI_FRIGATE_HEIGHT"       "$cf"
  set_or_append_conf_value FRIGATE_BIRDSEYE_MARGIN     "$TUI_FRIGATE_MARGIN"       "$cf"
  set_or_append_conf_value GUI_USER                    "$TUI_GUI_USER"             "$cf"
  set_or_append_conf_value HEALTH_INTERVAL             "$TUI_HEALTH_INTERVAL"      "$cf"
  set_or_append_conf_value SCREEN_DELAY                "$TUI_SCREEN_DELAY"         "$cf"
  set_or_append_conf_value STALL_RETRIES               "$TUI_STALL_RETRIES"        "$cf"
  set_or_append_conf_value VLC_STALL_RETRIES           "$TUI_VLC_STALL_RETRIES"    "$cf"
  set_or_append_conf_value HEALTH_RETRIES              "$TUI_HEALTH_RETRIES"       "$cf"
  set_or_append_conf_value MIN_UPTIME_BEFORE_START     "$TUI_MIN_UPTIME"           "$cf"
  set_or_append_conf_value GUI_SESSION_WAIT_TIMEOUT    "$TUI_SESSION_WAIT"         "$cf"
  set_or_append_conf_value WAYLAND_READY_TIMEOUT       "$TUI_WAYLAND_WAIT"         "$cf"
  set_or_append_conf_value LOG_MAX_BYTES               "$TUI_LOG_MAX_BYTES"        "$cf"
  set_or_append_conf_value LOG_ROTATE_KEEP             "$TUI_LOG_ROTATE_KEEP"      "$cf"
  set_or_append_conf_value PROFILE_TMPFS               "$TUI_PROFILE_TMPFS"        "$cf"
  set_or_append_conf_value PROFILE_SYNC_BACK           "$TUI_PROFILE_SYNC_BACK"    "$cf"
  set_or_append_conf_value PREWARM_ENABLED             "$TUI_PREWARM"              "$cf"
  set_or_append_conf_value VLC_LOOP                    "$TUI_VLC_LOOP"             "$cf"
  set_or_append_conf_value VLC_NO_AUDIO                "$TUI_VLC_NO_AUDIO"         "$cf"
  set_or_append_conf_value VLC_NETWORK_CACHING         "$TUI_VLC_NETWORK_CACHING"  "$cf"
  TUI_DIRTY="no"
}

_tui_save_and_exit() {
  if [ "$TUI_DIRTY" = "no" ]; then
    whiptail --title "Save" --msgbox "No pending changes to save." 10 50
    return 0
  fi
  _tui_write_all
  whiptail --title "Saved" --msgbox "Configuration written to $CONFIG_FILE." 10 70
  _tui_offer_restart
  return 1   # tell the caller the main loop should exit
}

_tui_offer_restart() {
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -qx 'kiosk-monitor.service' || {
    whiptail --title "Tip" --msgbox \
"kiosk-monitor.service is not installed yet.
Run 'sudo kiosk-monitor --install' to create it." 10 70
    return 0
  }
  local was_active="no"
  systemctl is-active --quiet kiosk-monitor.service && was_active="yes"
  local prompt
  if [ "$was_active" = "yes" ]; then
    prompt="Service is running. Restart it to apply the new config?"
  else
    prompt="Service is not running. Start it now?"
  fi
  if _wt_yesno "Apply" "$prompt"; then
    if [ "$was_active" = "yes" ]; then
      systemctl restart kiosk-monitor.service
    else
      systemctl start kiosk-monitor.service
    fi
  fi
}

_tui_main_menu() {
  local inst1_label inst2_label frig_label adv_label
  while true; do
    inst1_label="$TUI_MODE @ $(_tui_preview_value "$TUI_OUTPUT" auto) → $(_tui_preview_value "$TUI_URL" not-set)"
    if [ -n "$TUI_MODE2" ]; then
      inst2_label="$TUI_MODE2 @ $(_tui_preview_value "$TUI_OUTPUT2" auto) → $(_tui_preview_value "$TUI_URL2" not-set)"
    else
      inst2_label="disabled"
    fi
    frig_label="dark=$(_tui_preview_value "$TUI_FRIGATE_DARK" auto), theme=$(_tui_preview_value "$TUI_FRIGATE_THEME" auto), autofill=$TUI_FRIGATE_AUTOFILL"
    adv_label="interval=${TUI_HEALTH_INTERVAL}s, stall=${TUI_STALL_RETRIES}/${TUI_VLC_STALL_RETRIES}"

    local dirty_marker=""
    [ "$TUI_DIRTY" = "yes" ] && dirty_marker=" *"
    local choice
    choice=$(_wt_menu "kiosk-monitor ${SCRIPT_VERSION}${dirty_marker}" \
      "Main menu — pick an area to edit, or save and exit." 20 78 10 \
      "instance1"  "Instance 1:  $inst1_label" \
      "instance2"  "Instance 2:  $inst2_label" \
      "frigate"    "Frigate helper:  $frig_label" \
      "timing"     "Timing & restart thresholds:  $adv_label" \
      "profile"    "Profile / logging / VLC options" \
      "editor"     "Open $CONFIG_FILE in \$EDITOR" \
      "reload"     "Reload config file (discard in-memory edits)" \
      "save"       "Save changes and exit" \
      "quit"       "Discard changes and exit") || return 0
    case "$choice" in
      instance1) _tui_edit_instance 1 TUI_MODE TUI_URL TUI_OUTPUT TUI_RES TUI_ROT ;;
      instance2) _tui_edit_instance2 ;;
      frigate)   _tui_edit_frigate ;;
      timing)    _tui_edit_timing ;;
      profile)   _tui_edit_profile_logs ;;
      editor)    _tui_edit_in_editor ;;
      reload)
        _tui_load_config
        whiptail --title "Reloaded" --msgbox "Re-read $CONFIG_FILE into memory." 10 60 ;;
      save)
        _tui_save_and_exit && continue
        return 0 ;;
      quit)
        if [ "$TUI_DIRTY" = "yes" ]; then
          _wt_yesno "Discard changes?" "You have unsaved changes. Discard them and exit?" no \
            && return 0 || continue
        fi
        return 0 ;;
    esac
  done
}

configure_self() {
  require_root
  if ! command -v whiptail >/dev/null 2>&1; then
    echo "Error: whiptail not installed. Run: sudo apt install whiptail" >&2
    exit 1
  fi
  _tui_load_config
  _tui_probe_outputs
  _tui_main_menu
}

logs_self() {
  need_cmd journalctl
  local follow="yes" lines=200
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-follow|-n)  follow="no" ;;
      --follow|-f)     follow="yes" ;;
      --lines)         shift; lines="${1:-200}" ;;
      --lines=*)       lines="${1#--lines=}" ;;
      --all)           lines="all" ;;
      *) printf 'Error: unknown logs option %s\n' "$1" >&2; usage; exit 1 ;;
    esac
    shift
  done
  local -a cmd=( journalctl -u kiosk-monitor.service --no-pager )
  case "$lines" in all|0) ;; *) cmd+=( -n "$lines" ) ;; esac
  [ "$follow" = "yes" ] && cmd+=( -f )
  exec "${cmd[@]}"
}

status_self() {
  printf 'kiosk-monitor version: %s\n' "$SCRIPT_VERSION"
  printf 'Config file:           %s\n' "$CONFIG_FILE"
  printf 'Desktop user (config): %s\n' "${GUI_USER:-auto-detect}"
  printf '\nInstance 1:\n'
  printf '  mode        : %s\n' "${MODE:-unset}"
  printf '  url         : %s\n' "${URL:-unset}"
  printf '  output      : %s\n' "${OUTPUT:-(auto)}"
  printf '  resolution  : %s\n' "${FORCE_RESOLUTION:-(compositor)}"
  printf '  rotation    : %s\n' "${FORCE_ROTATION:-(compositor)}"
  if [ -n "${MODE2:-}" ]; then
    printf '\nInstance 2:\n'
    printf '  mode        : %s\n' "$MODE2"
    printf '  url         : %s\n' "${URL2:-unset}"
    printf '  output      : %s\n' "${OUTPUT2:-(auto)}"
    printf '  resolution  : %s\n' "${FORCE_RESOLUTION_2:-(compositor)}"
    printf '  rotation    : %s\n' "${FORCE_ROTATION_2:-(compositor)}"
  else
    printf '\nInstance 2: disabled\n'
  fi
  if [ "$MODE" = "chrome" ] || [ -n "${MODE2:-}" ] && [ "${MODE2:-}" = "chrome" ]; then
    printf '\nFrigate helper:\n'
    printf '  dark-mode         : %s\n' "${FRIGATE_DARK_MODE:-(none)}"
    printf '  theme             : %s\n' "${FRIGATE_THEME:-(none)}"
    printf '  birdseye autofill : %s\n' "${FRIGATE_BIRDSEYE_AUTO_FILL:-false}"
    if [ -n "${FRIGATE_BIRDSEYE_WIDTH:-}" ] || [ -n "${FRIGATE_BIRDSEYE_HEIGHT:-}" ]; then
      printf '  birdseye size     : %sx%s (fixed)\n' "${FRIGATE_BIRDSEYE_WIDTH:-auto}" "${FRIGATE_BIRDSEYE_HEIGHT:-auto}"
    else
      printf '  birdseye size     : auto (viewport minus %spx margin)\n' "${FRIGATE_BIRDSEYE_MARGIN:-80}"
    fi
  fi
  if [ -n "${LOG:-}" ] && [ -f "$LOG" ]; then
    local lsize
    lsize=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    printf '\nLog file:   %s (%s bytes; cap %s)\n' "$LOG" "$lsize" "${LOG_MAX_BYTES:-2097152}"
  fi
  echo
  if command -v systemctl >/dev/null 2>&1; then
    systemctl status kiosk-monitor.service --no-pager 2>/dev/null || true
  fi
}

usage() {
  cat <<'EOF'
kiosk-monitor — Browser/VLC kiosk watchdog (v6, Wayland + labwc)

Usage:
  kiosk-monitor                           Open the interactive TUI (terminal-only default)
  kiosk-monitor --run                     Run the watchdog (used by systemd ExecStart)
  kiosk-monitor --configure               Same TUI, explicit
  kiosk-monitor --install [--url URL] [--mode chrome|vlc] [--output NAME]
                          [--url2 URL] [--mode2 chrome|vlc] [--output2 NAME]
                          [--gui-user USER] [--no-start] [--skip-apt]
  kiosk-monitor --update  [--check] [--local] [--force] [--base-url URL]
                          [--gui-user USER] [--mode chrome|vlc] [--no-restart] [--skip-apt]
  kiosk-monitor --remove  [--purge]
  kiosk-monitor --reconfig | --reconfigure [--config PATH]
  kiosk-monitor --status
  kiosk-monitor --logs [--no-follow] [--lines N|all]
  kiosk-monitor --help | --version

Config (/etc/kiosk-monitor/kiosk-monitor.conf):
  MODE       chrome or vlc                     (instance 1, required)
  URL        target URL/stream                 (instance 1, required)
  OUTPUT     output name e.g. HDMI-A-1         (optional; auto-detect)
  MODE2      chrome, vlc, or empty             (instance 2, optional)
  URL2       target URL/stream                 (instance 2)
  OUTPUT2    output name e.g. HDMI-A-2         (instance 2)

Run as root for install/update/remove/reconfig. Runtime service runs as
the detected desktop user. Prereqs on Raspberry Pi OS trixie Desktop are
preinstalled (chromium, vlc, grim, wlr-randr, curl, python3).
EOF
}

# ======================================================================
# Action dispatch
# ======================================================================
ACTION=""
case "${1:-}" in
  --install|--remove|--update|--configure) ACTION="${1#--}"; shift ;;
  --reconfig|--reconfigure)                ACTION="reconfig"; shift ;;
  --run)     ACTION="run";     shift ;;
  --status)  ACTION="status";  shift ;;
  --logs)    ACTION="logs";    shift ;;
  --help|-h) ACTION="help";    shift ;;
  --version) ACTION="version"; shift ;;
esac

# No action given: if stdin + stdout are a terminal, open the configuration
# TUI (most useful default for an operator). Non-interactive callers (cron,
# systemd, subprocess) must pass --run explicitly — refusing silent starts
# prevents the watchdog from firing off unintentionally.
if [ -z "$ACTION" ]; then
  if [ "$#" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
    ACTION="configure"
  else
    cat >&2 <<EOF
$SCRIPT_NAME: no action specified.

Run the TUI from a terminal:       $SCRIPT_NAME         (interactive)
Or pass a subcommand, for example: $SCRIPT_NAME --run   (watchdog)
See: $SCRIPT_NAME --help
EOF
    exit 1
  fi
fi
ACTION_ARGS=("$@")

case "$ACTION" in
  install)   install_self "${ACTION_ARGS[@]}"; exit 0 ;;
  update)    update_self  "${ACTION_ARGS[@]}"; exit 0 ;;
  remove)    remove_self  "${ACTION_ARGS[@]}"; exit 0 ;;
  configure) configure_self;                    exit 0 ;;
  reconfig)  reconfigure_self;                  exit 0 ;;
  status)    status_self;                       exit 0 ;;
  logs)      logs_self    "${ACTION_ARGS[@]}"; exit 0 ;;
  help)      usage;                             exit 0 ;;
  version)   printf '%s\n' "$SCRIPT_VERSION";   exit 0 ;;
esac

# ======================================================================
# RUNTIME (ACTION=run)
# ======================================================================
set -- "${ACTION_ARGS[@]}"

DEBUG=${DEBUG:-false}
for arg in "$@"; do
  if [ "$arg" = "--debug" ]; then DEBUG=true; set -- "${@/--debug/}"; break; fi
done
DEBUG=$(printf '%s' "$DEBUG" | tr '[:upper:]' '[:lower:]')

# --- logging ---
LOG_DEFAULT="/dev/shm/kiosk.log"
LOG="${LOG:-$LOG_DEFAULT}"
requested_log="$LOG"
if ! init_log_file "$LOG"; then
  fallback_log="/tmp/kiosk-monitor-${UID}.log"
  if init_log_file "$fallback_log"; then
    [ "$requested_log" != "$fallback_log" ] && printf 'Warning: unable to write to %s; logging to %s instead\n' "$requested_log" "$fallback_log" >&2
    LOG="$fallback_log"
  else
    printf 'Error: could not initialise log file at %s or %s\n' "$requested_log" "$fallback_log" >&2
    exit 1
  fi
fi
exec > >(tee -a "$LOG") 2>&1

need_cmd curl; need_cmd flock; need_cmd sha256sum; need_cmd python3
need_cmd grim; need_cmd wlr-randr

# --- lock ---
requested_lock="$LOCK_FILE"
if ! open_lock_file "$requested_lock"; then
  fallback_base="${XDG_RUNTIME_DIR:-}"
  [ -n "$fallback_base" ] && ! mkdir -p "$fallback_base" 2>/dev/null && fallback_base=""
  [ -z "$fallback_base" ] && fallback_base="/tmp"
  lock_fallback="${fallback_base%/}/kiosk-monitor-${UID}.lock"
  if open_lock_file "$lock_fallback"; then
    [ "$requested_lock" != "$lock_fallback" ] && printf 'Warning: unable to acquire lock at %s; using %s\n' "$requested_lock" "$lock_fallback" >&2
  else
    printf 'Error: could not create lock file at %s or %s\n' "$requested_lock" "$lock_fallback" >&2
    exit 1
  fi
fi
if ! flock -n 200; then
  echo "Another kiosk-monitor instance is already running (lock $LOCK_FILE)." >&2
  exit 0
fi

[ "$DEBUG" = "true" ] && set -x

ensure_minimum_uptime

# --- identify desktop user ---
if [ -z "${GUI_USER:-}" ] || [ "$GUI_USER" = "root" ]; then
  if ! auto_detect_gui_user; then
    echo "Error: could not detect a desktop user and GUI_USER is unset." >&2
    exit 1
  fi
fi
GUI_UID=$(id -u "$GUI_USER")
[ "${EUID:-$(id -u)}" -eq 0 ] && chown "$GUI_USER":"$GUI_USER" "$LOG" 2>/dev/null || true
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${GUI_UID}}"
if [ ! -d "$XDG_RUNTIME_DIR" ] && [ "${EUID:-$(id -u)}" -eq 0 ]; then
  mkdir -p "$XDG_RUNTIME_DIR"
  chown "$GUI_USER":"$GUI_USER" "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"
fi

# --- install signal traps BEFORE any blocking wait. SIGHUP arriving while
#     we're waiting for the compositor used to kill bash outright. ---
handle_reload_signal() {
  RELOAD_REQUESTED=true
}
handle_shutdown_signal() {
  [ "$SHUTDOWN_REQUESTED" = "true" ] && return
  SHUTDOWN_REQUESTED=true
  log "Termination signal received — shutting down kiosk-monitor."
  local id
  for id in "${INSTANCES[@]:-}"; do stop_instance "$id" 2>/dev/null || true; done
  exit 0
}
trap handle_shutdown_signal INT TERM
trap handle_reload_signal HUP

# --- wait for labwc + wayland socket (desktop open) ---
wait_for_gui_session
if ! wait_for_wayland_ready "$GUI_UID"; then
  log "Exiting — no supported compositor. systemd will restart us; fix the"
  log "desktop session first (see the previous log lines for guidance)."
  exit 1
fi

# --- profile runtime (shared among chrome instances) ---
PROFILE_PERSIST_ROOT="${PROFILE_ROOT:-/home/${GUI_USER}/.local/share/kiosk-monitor}"
PROFILE_RUNTIME_ROOT="$PROFILE_PERSIST_ROOT"
prepare_profile_runtime
start_profile_sync_timer

# --- deprecation notice (legacy BIRDSEYE_* names) ---
if [ -n "${BIRDSEYE_AUTO_FILL:-}${BIRDSEYE_MATCH_PATTERN:-}${BIRDSEYE_EXTENSION_DIR:-}" ]; then
  log "Notice: BIRDSEYE_* config names are deprecated — rename to FRIGATE_BIRDSEYE_*."
fi

# --- config validation ---
validate_runtime_config || exit 1

# --- instance configuration ---
setup_instances

# --- outputs ---
if ! refresh_outputs; then
  log "Warning: wlr-randr output discovery failed; window placement will use defaults"
  OUTPUTS_NAMES=( "HDMI-A-1" )
  OUTPUT_GEOMETRY["HDMI-A-1"]="0 0 1920 1080"
fi
for id in "${INSTANCES[@]}"; do
  # rc=1 means the requested output isn't connected yet — we still store the
  # name so the main loop can pause until it returns.
  resolve_output_geometry "$id" >/dev/null || true
  log_instance "$id" "resolved output=${INSTANCE_OUTPUT[$id]}"
  apply_display_overrides "$id"
done
# Install labwc window rules so each instance lands on the right output.
ensure_labwc_window_rules

# --- exit cleanup (INT/TERM/HUP traps were installed earlier so they're
#     active during the Wayland / GUI wait) ---
cleanup() {
  local status=$?
  trap - EXIT
  local id
  for id in "${INSTANCES[@]:-}"; do stop_instance "$id" 2>/dev/null || true; done
  if [ -n "$PROFILE_SYNC_PID" ] && kill -0 "$PROFILE_SYNC_PID" 2>/dev/null; then
    kill "$PROFILE_SYNC_PID" 2>/dev/null || true
    wait "$PROFILE_SYNC_PID" 2>/dev/null || true
  fi
  sync_profile_persist true
  flock -u 200 2>/dev/null || true
  exec 200>&- 2>/dev/null || true
  log "==== STOP kiosk-monitor ===="
  exit "$status"
}
trap cleanup EXIT

log "==== START kiosk-monitor v$SCRIPT_VERSION at $(date -Is) ===="
log "Desktop user: $GUI_USER (uid=$GUI_UID), WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-?}"
log "Outputs: ${OUTPUTS_NAMES[*]:-none}"
log "Instances: ${INSTANCES[*]}"

# --- health-gate for chrome instances with http URLs ---
if [ "$WAIT_FOR_URL" = "true" ]; then
  for id in "${INSTANCES[@]}"; do
    if [ "${INSTANCE_MODE[$id]}" = "chrome" ]; then
      log_instance "$id" "waiting for ${INSTANCE_URL[$id]} …"
      wait_for_url_ready_instance "$id" || true
    fi
  done
fi

# --- initial launch ---
for id in "${INSTANCES[@]}"; do
  launch_instance "$id" || log_instance "$id" "initial launch failed; watchdog will retry"
  INSTANCE_LAST_GOOD[$id]=$(date +%s)
  INSTANCE_LAST_HASH[$id]=$(capture_output_hash "$id" || true)
done

# --- main watchdog loop ---
reload_instances() {
  log "SIGHUP received — reloading configuration from $CONFIG_FILE."
  local id
  for id in "${INSTANCES[@]}"; do stop_instance "$id"; done
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
  # Re-apply smart defaults + basic mode normalization. Full normalization
  # happens only at script startup; these are the bits that matter for
  # deciding what to launch on reload.
  apply_frigate_smart_defaults
  MODE=$(printf '%s' "${MODE:-chrome}" | tr '[:upper:]' '[:lower:]')
  MODE2=$(printf '%s' "${MODE2:-}"    | tr '[:upper:]' '[:lower:]')
  case "$MODE"  in chromium|chrome) MODE="chrome" ;; esac
  case "$MODE2" in chromium|chrome) MODE2="chrome" ;; esac
  FRIGATE_BIRDSEYE_AUTO_FILL="${FRIGATE_BIRDSEYE_AUTO_FILL:-false}"
  validate_runtime_config || { log "Reload aborted: config invalid."; return 1; }
  setup_instances
  refresh_outputs || true
  ensure_labwc_window_rules
  for id in "${INSTANCES[@]}"; do
    resolve_output_geometry "$id" >/dev/null || true
    log_instance "$id" "resolved output=${INSTANCE_OUTPUT[$id]}"
    apply_display_overrides "$id"
    launch_instance "$id" || log_instance "$id" "reload launch failed"
    INSTANCE_LAST_GOOD[$id]=$(date +%s)
    INSTANCE_LAST_HASH[$id]=$(capture_output_hash "$id" || true)
  done
  log "Configuration reloaded."
}

while true; do
  if [ "$RELOAD_REQUESTED" = "true" ]; then
    RELOAD_REQUESTED=false
    reload_instances || true
    continue
  fi
  rotate_log_if_needed
  refresh_outputs || true
  now=$(date +%s)
  for id in "${INSTANCES[@]}"; do
    pid="${INSTANCE_PID[$id]:-}"

    # 0. HDMI hotplug: pause when the instance's requested output is gone;
    #    resume when it returns. Instances with no explicit OUTPUT skip this.
    if [ -n "${INSTANCE_OUTPUT[$id]:-}" ] && ! instance_output_present "$id"; then
      if [ "${INSTANCE_PAUSED[$id]:-no}" != "yes" ]; then
        log_instance "$id" "output '${INSTANCE_OUTPUT[$id]}' not connected — pausing"
        stop_instance "$id"
        INSTANCE_PAUSED[$id]="yes"
      fi
      continue
    fi
    if [ "${INSTANCE_PAUSED[$id]:-no}" = "yes" ]; then
      log_instance "$id" "output '${INSTANCE_OUTPUT[$id]}' reconnected — resuming"
      INSTANCE_PAUSED[$id]="no"
      INSTANCE_RESTART_LOG[$id]=""
      apply_display_overrides "$id"
      launch_instance "$id" || log_instance "$id" "relaunch after hotplug failed; will retry"
      INSTANCE_LAST_GOOD[$id]=$now
      INSTANCE_LAST_HASH[$id]=$(capture_output_hash "$id" || true)
      continue
    fi

    # 1. process liveness
    if ! process_alive "$pid"; then
      log_instance "$id" "PID $pid vanished — restarting"
      record_restart_instance "$id"
      continue
    fi

    # 2. for chrome, prune stray browsers and resolve main PID if needed
    if [ "${INSTANCE_MODE[$id]}" = "chrome" ]; then
      mapfile -t actives < <(pgrep -u "$GUI_USER" -f -- "${INSTANCE_MATCH[$id]}" 2>/dev/null || true)
      if [ "${#actives[@]}" -eq 0 ]; then
        log_instance "$id" "no matching processes — restarting"
        record_restart_instance "$id"
        continue
      fi
      # (we don't force-prune here; --user-data-dir ensures uniqueness per instance)
    fi

    # 3. health check (http only)
    if health_check_instance "$id"; then
      INSTANCE_FAIL_COUNT[$id]=0
      INSTANCE_LAST_GOOD[$id]=$now
    else
      case "${INSTANCE_URL[$id]}" in
        http://*|https://*)
          INSTANCE_FAIL_COUNT[$id]=$((INSTANCE_FAIL_COUNT[$id] + 1))
          log_instance "$id" "health failed ${INSTANCE_FAIL_COUNT[$id]}/${HEALTH_RETRIES}"
          ;;
      esac
    fi

    # 4. freeze / stall detection via per-output hash
    proc_age=$(ps -p "$pid" -o etimes= --no-headers 2>/dev/null | tr -d ' ' || echo 0)
    [[ "$proc_age" =~ ^[0-9]+$ ]] || proc_age=0
    if [ "$proc_age" -ge "$SCREEN_DELAY" ]; then
      curr_hash=$(capture_output_hash "$id" || true)
      if [ -n "$curr_hash" ]; then
        if [ -n "${INSTANCE_LAST_HASH[$id]}" ] && [ "$curr_hash" = "${INSTANCE_LAST_HASH[$id]}" ]; then
          INSTANCE_STALL_COUNT[$id]=$((INSTANCE_STALL_COUNT[$id] + 1))
          threshold="${INSTANCE_STALL_THRESHOLD[$id]:-$STALL_RETRIES}"
          log_instance "$id" "screen unchanged ${INSTANCE_STALL_COUNT[$id]}/${threshold}"
        else
          INSTANCE_STALL_COUNT[$id]=0
          INSTANCE_LAST_HASH[$id]=$curr_hash
        fi
      else
        debug_instance "$id" "hash capture returned empty; skipping"
      fi
    fi

    # 5. cleanup restart history after healthy stretch
    if [ $((now - INSTANCE_LAST_GOOD[$id])) -gt "$CLEAN_RESET" ]; then
      INSTANCE_RESTART_LOG[$id]=""
    fi

    # 6. decide whether to restart
    threshold="${INSTANCE_STALL_THRESHOLD[$id]:-$STALL_RETRIES}"
    if [ "${INSTANCE_STALL_COUNT[$id]}" -ge "$threshold" ]; then
      log_instance "$id" "screen appears frozen — restarting"
      INSTANCE_STALL_COUNT[$id]=0
      record_restart_instance "$id"
      continue
    fi
    if [ "${INSTANCE_FAIL_COUNT[$id]}" -ge "$HEALTH_RETRIES" ]; then
      log_instance "$id" "health-failure threshold reached — restarting"
      INSTANCE_FAIL_COUNT[$id]=0
      record_restart_instance "$id"
      continue
    fi
  done
  # SIGHUP delivered during sleep makes sleep exit non-zero; swallow it so
  # `set -e` doesn't treat the interrupted wait as a hard error.
  sleep "$HEALTH_INTERVAL" || true
done
