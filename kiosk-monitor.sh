#!/usr/bin/env bash
# ======================================================================
# Coded by Adrian Jon Kriel :: admin@extremeshok.com
# ======================================================================
# kiosk-monitor.sh :: version 6.0.0
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

SCRIPT_VERSION="6.0.0"
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
DEFAULT_BASE_URL="https://raw.githubusercontent.com/extremeshok/kiosk-monitor/main"
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

# Chromium-specific
CHROMIUM_BIN="${CHROMIUM_BIN:-}"
BIRDSEYE_AUTO_FILL="${BIRDSEYE_AUTO_FILL:-false}"
BIRDSEYE_MATCH_PATTERN="${BIRDSEYE_MATCH_PATTERN:-}"
BIRDSEYE_EXTENSION_DIR="${BIRDSEYE_EXTENSION_DIR:-}"
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

# Normalize booleans/strings (lower-case)
for _var in MODE MODE2 VLC_LOOP VLC_NO_AUDIO PROFILE_TMPFS PROFILE_SYNC_BACK PROFILE_TMPFS_PURGE \
            PREWARM_ENABLED BIRDSEYE_AUTO_FILL DEVTOOLS_AUTO_OPEN WAIT_FOR_URL; do
  val="${!_var}"
  val="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
  printf -v "$_var" '%s' "$val"
done
unset _var val

case "$MODE" in chromium|chrome) MODE="chrome" ;; esac
case "$MODE2" in chromium|chrome) MODE2="chrome" ;; esac

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

wait_for_wayland_ready() {
  local uid=${1:-$GUI_UID}
  local timeout="${WAYLAND_READY_TIMEOUT:-0}"
  [[ "$timeout" =~ ^[0-9]+$ ]] && [ "$timeout" -gt 0 ] || timeout=0
  local rt="/run/user/${uid}"
  local waited=0
  local found=""
  while true; do
    if [ -d "$rt" ]; then
      for sock in "$rt"/wayland-*; do
        [ -S "$sock" ] || continue
        case "$sock" in *.lock) continue ;; esac
        found=$(basename "$sock")
        break
      done
    fi
    # also require the compositor to be up
    if [ -n "$found" ] && pgrep -u "$uid" -x labwc >/dev/null 2>&1; then
      WAYLAND_DISPLAY="$found"
      export WAYLAND_DISPLAY
      log "Desktop session ready: wayland socket=$WAYLAND_DISPLAY, compositor=labwc."
      return 0
    fi
    if [ "$timeout" -gt 0 ] && [ "$waited" -ge "$timeout" ]; then
      log "Wayland/labwc not ready after ${timeout}s; proceeding (compositor may still come up)."
      [ -n "$found" ] && { WAYLAND_DISPLAY="$found"; export WAYLAND_DISPLAY; }
      return 0
    fi
    if [ $((waited % 15)) -eq 0 ]; then
      log "Waiting for labwc + wayland socket in $rt (waited ${waited}s)…"
    fi
    sleep 2
    waited=$((waited + 2))
  done
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
          "$@"
  fi
}

refresh_outputs() {
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
    log_instance "$id" "Requested output '$requested' not available yet; current outputs: ${OUTPUTS_NAMES[*]:-none}"
  fi
  # pick the Nth available output by id order
  local idx=0 name
  for name in "${OUTPUTS_NAMES[@]}"; do
    idx=$((idx + 1))
    if [ "$idx" = "$id" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  # fallback to first output
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

ensure_birdseye_extension() {
  local id=$1
  [ "$BIRDSEYE_AUTO_FILL" = "true" ] || return 1
  local profile_root=${INSTANCE_PROFILE_DIR[$id]}
  local url="${INSTANCE_URL[$id]}"
  local -a candidates=()
  [ -n "$BIRDSEYE_EXTENSION_DIR" ] && candidates+=( "${BIRDSEYE_EXTENSION_DIR%/}/$id" )
  candidates+=( "${profile_root%/}/birdseye-autofill" "/usr/local/share/kiosk-monitor/birdseye-autofill-$id" )
  local dir="" candidate
  for candidate in "${candidates[@]}"; do
    [ -n "$candidate" ] || continue
    if mkdir -p "$candidate" 2>/dev/null; then dir="$candidate"; break; fi
  done
  [ -n "$dir" ] || return 1
  local match_pattern="$BIRDSEYE_MATCH_PATTERN"
  [ -z "$match_pattern" ] && match_pattern=$(derive_match_pattern "$url")
  cat > "$dir/fullscreen.css" <<'CSS'
/* Ensure Frigate Birdseye grid/canvas fill the viewport */
#pageRoot > div > div > div > div.react-grid-layout.grid-layout {
  height: 100vh !important;
  width: 100vw !important;
}
#pageRoot > div > div > div > div.react-grid-layout.grid-layout > div > div > div.size-full > div > div > div > canvas {
  height: 100% !important;
  width: 100% !important;
}
CSS
  cat > "$dir/manifest.json" <<MANIFEST
{
  "name": "Frigate Birdseye Auto-Fill",
  "version": "1.0",
  "manifest_version": 3,
  "description": "Force the Frigate Birdseye grid to fill the window.",
  "content_scripts": [
    {
      "matches": ["$match_pattern"],
      "css": ["fullscreen.css"],
      "run_at": "document_start"
    }
  ]
}
MANIFEST
  chmod 0644 "$dir/fullscreen.css" "$dir/manifest.json"
  chmod 0755 "$dir"
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
    --ozone-platform=wayland
    --password-store=basic
    --allow-running-insecure-content
    "--user-data-dir=$profile_root"
    "--window-position=${x},${y}"
    "--window-size=${w},${h}"
    --new-window
  )
  local ext_path
  if ext_path=$(ensure_birdseye_extension "$id"); then
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
  as_gui "$vlc" "${flags[@]}" >/dev/null 2>&1 &
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
  local -a cmd=( as_gui grim )
  [ -n "$name" ] && cmd+=( -o "$name" )
  cmd+=( -t ppm - )
  if ! "${cmd[@]}" >"$tmp" 2>/dev/null; then
    debug_instance "$id" "grim capture failed (output=$name)"
    rm -f "$tmp"; return 1
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
  if [ -n "$MODE2" ]; then
    INSTANCES+=( 2 )
    INSTANCE_MODE[2]="$MODE2"
    INSTANCE_URL[2]="${URL2:-$URL}"
    INSTANCE_OUTPUT[2]="$OUTPUT2"
  fi
  local id
  for id in "${INSTANCES[@]}"; do
    INSTANCE_PID[$id]=""
    INSTANCE_LAST_HASH[$id]=""
    INSTANCE_STALL_COUNT[$id]=0
    INSTANCE_FAIL_COUNT[$id]=0
    INSTANCE_LAST_GOOD[$id]=$(date +%s)
    INSTANCE_RESTART_LOG[$id]=""
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
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-enabled --quiet tailscaled.service >/dev/null 2>&1 && { printf 'tailscaled.service\n'; return 0; }
  return 1
}

ensure_script_installed() {
  local source=$1 target=$2 dir
  dir=$(dirname "$target"); mkdir -p "$dir"
  local source_real target_real=""
  source_real=$(readlink -f "$source" 2>/dev/null || printf '%s' "$source")
  target_real=$(readlink -f "$target" 2>/dev/null || printf '')
  if [ -n "$target_real" ] && [ "$source_real" = "$target_real" ]; then
    chmod 0755 "$target"; return 0
  fi
  install -m 0755 "$source" "$target"
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
    emit_config_line MODE2        "${MODE2:-}"
    emit_config_line URL2         "${URL2:-}"
    emit_config_line OUTPUT2      "${OUTPUT2:-}"
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
    emit_config_line BIRDSEYE_AUTO_FILL "${BIRDSEYE_AUTO_FILL:-false}"
    emit_config_line BIRDSEYE_MATCH_PATTERN "${BIRDSEYE_MATCH_PATTERN:-}"
    emit_config_line BIRDSEYE_EXTENSION_DIR "${BIRDSEYE_EXTENSION_DIR:-}"
    emit_config_line DEVTOOLS_AUTO_OPEN "${DEVTOOLS_AUTO_OPEN:-false}"
    emit_config_line DEVTOOLS_REMOTE_PORT "${DEVTOOLS_REMOTE_PORT:-}"
    emit_config_line LOCK_FILE "${LOCK_FILE:-/var/lock/kiosk-monitor.lock}"
    emit_config_line INSTALL_DIR "${INSTALL_DIR:-/usr/local/bin}"
    emit_config_line SERVICE_PATH "${SERVICE_PATH:-/etc/systemd/system/kiosk-monitor.service}"
    emit_config_line BASE_URL "${BASE_URL:-$DEFAULT_BASE_URL}"
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

install_self() {
  require_root
  need_cmd systemctl; need_cmd install

  local url_override="" gui_override="" mode_override=""
  local output_override="" mode2_override="" url2_override="" output2_override=""
  local autostart="yes"
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
      --base-url)   shift; BASE_URL="${1:-}";          [ -n "$BASE_URL" ]         || { echo 'Error: --base-url requires a value' >&2; exit 1; } ;;
      *) printf 'Error: unknown install option %s\n' "$1" >&2; usage; exit 1 ;;
    esac
    shift
  done

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
  ensure_script_installed "$resolved_script" "$INSTALL_DIR/kiosk-monitor.sh"

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

update_self() {
  require_root
  need_cmd systemctl; need_cmd install
  local gui_override="" mode_override="" suppress_restart="no"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --gui-user|--user) shift; gui_override="${1:-}"; [ -n "$gui_override" ] || { echo 'Error: --gui-user requires a value' >&2; exit 1; } ;;
      --mode)       shift; mode_override="${1:-}"; mode_override=$(printf '%s' "$mode_override" | tr '[:upper:]' '[:lower:]')
                    case "$mode_override" in chromium|chrome) mode_override="chrome" ;; esac ;;
      --browser)    shift; mode_override="${1:-}"; case "$mode_override" in chromium|chrome) mode_override="chrome" ;; vlc|VLC) mode_override="vlc" ;; esac ;;
      --no-restart) suppress_restart="yes" ;;
      --base-url)   shift; echo 'Warning: --base-url is deprecated and ignored.' >&2 ;;
      *) printf 'Error: unknown update option %s\n' "$1" >&2; usage; exit 1 ;;
    esac
    shift
  done

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

  local resolved_script script_dir
  resolved_script=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
  script_dir=$(dirname "$resolved_script")
  mkdir -p "$INSTALL_DIR"
  ensure_script_installed "$resolved_script" "$INSTALL_DIR/kiosk-monitor.sh"

  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONFIG_DIR/kiosk-monitor.conf.sample" ] && [ -f "$script_dir/kiosk-monitor.conf.sample" ]; then
    install -m 0644 "$script_dir/kiosk-monitor.conf.sample" "$CONFIG_DIR/kiosk-monitor.conf.sample"
  fi
  [ -n "$mode_override" ] && ensure_config_file "" "" "$mode_override" "" "" "" ""

  local service_dependency=""
  local dep
  if dep=$(tailscaled_dependency_unit); then service_dependency="$dep"; fi
  write_service_unit "$effective_gui" "$runtime_dir" "$wayland_display" "$SERVICE_PATH" "$service_dependency"
  systemctl daemon-reload
  if [ "$was_active" = "yes" ] && [ "$suppress_restart" = "no" ]; then
    systemctl restart kiosk-monitor.service
    echo 'kiosk-monitor updated and restarted.'
  else
    echo 'kiosk-monitor updated.'
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
  rm -f "$INSTALL_DIR/kiosk-monitor.sh"
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

status_self() {
  printf 'kiosk-monitor version: %s\n' "$SCRIPT_VERSION"
  printf 'Config file: %s\n' "$CONFIG_FILE"
  printf 'Instance 1: mode=%s url=%s output=%s\n' "${MODE:-unset}" "${URL:-unset}" "${OUTPUT:-auto}"
  if [ -n "${MODE2:-}" ]; then
    printf 'Instance 2: mode=%s url=%s output=%s\n' "$MODE2" "${URL2:-unset}" "${OUTPUT2:-auto}"
  else
    printf 'Instance 2: disabled\n'
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl status kiosk-monitor.service --no-pager 2>/dev/null || true
  fi
}

usage() {
  cat <<'EOF'
kiosk-monitor.sh — Browser/VLC kiosk watchdog (v6, Wayland + labwc)

Usage:
  kiosk-monitor.sh [--debug]
  kiosk-monitor.sh --install [--url URL] [--mode chrome|vlc] [--output NAME]
                             [--url2 URL] [--mode2 chrome|vlc] [--output2 NAME]
                             [--gui-user USER] [--no-start]
  kiosk-monitor.sh --update  [--gui-user USER] [--mode chrome|vlc] [--no-restart]
  kiosk-monitor.sh --remove  [--purge]
  kiosk-monitor.sh --reconfig [--config PATH]
  kiosk-monitor.sh --status
  kiosk-monitor.sh --help | --version

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
ACTION="run"
case "${1:-}" in
  --install|--remove|--update|--reconfig) ACTION="${1#--}"; shift ;;
  --status)  ACTION="status"; shift ;;
  --help|-h) ACTION="help"; shift ;;
  --version) ACTION="version"; shift ;;
esac
ACTION_ARGS=("$@")

case "$ACTION" in
  install)  install_self "${ACTION_ARGS[@]}"; exit 0 ;;
  update)   update_self  "${ACTION_ARGS[@]}"; exit 0 ;;
  remove)   remove_self  "${ACTION_ARGS[@]}"; exit 0 ;;
  reconfig) reconfigure_self;                 exit 0 ;;
  status)   status_self;                      exit 0 ;;
  help)     usage;                            exit 0 ;;
  version)  printf '%s\n' "$SCRIPT_VERSION";  exit 0 ;;
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

# --- wait for labwc + wayland socket (desktop open) ---
wait_for_gui_session
wait_for_wayland_ready "$GUI_UID"

# --- profile runtime (shared among chrome instances) ---
PROFILE_PERSIST_ROOT="${PROFILE_ROOT:-/home/${GUI_USER}/.local/share/kiosk-monitor}"
PROFILE_RUNTIME_ROOT="$PROFILE_PERSIST_ROOT"
prepare_profile_runtime
start_profile_sync_timer

# --- instance configuration ---
setup_instances

# --- outputs ---
if ! refresh_outputs; then
  log "Warning: wlr-randr output discovery failed; window placement will use defaults"
  OUTPUTS_NAMES=( "HDMI-A-1" )
  OUTPUT_GEOMETRY["HDMI-A-1"]="0 0 1920 1080"
fi
for id in "${INSTANCES[@]}"; do
  resolve_output_geometry "$id" >/dev/null
  log_instance "$id" "resolved output=${INSTANCE_OUTPUT[$id]}"
done

# --- signal/exit handling ---
handle_shutdown_signal() {
  [ "$SHUTDOWN_REQUESTED" = "true" ] && return
  SHUTDOWN_REQUESTED=true
  log "Termination signal received — shutting down kiosk-monitor."
  local id
  for id in "${INSTANCES[@]}"; do stop_instance "$id"; done
  exit 0
}
cleanup() {
  local status=$?
  trap - EXIT
  local id
  for id in "${INSTANCES[@]}"; do stop_instance "$id" 2>/dev/null || true; done
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
trap handle_shutdown_signal INT TERM

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
while true; do
  refresh_outputs || true
  now=$(date +%s)
  for id in "${INSTANCES[@]}"; do
    pid="${INSTANCE_PID[$id]:-}"

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
  sleep "$HEALTH_INTERVAL"
done
