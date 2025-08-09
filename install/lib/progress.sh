#!/usr/bin/env bash
# Reusable lightweight progress bar utilities for Crucible
# Inspired by patterns from open-source bash progress bars.
# Usage:
#   source "$(dirname "$BASH_SOURCE")/progress.sh"
#   pb_init TOTAL "Message..."
#   pb_tick            # increments by 1
#   pb_add N           # increments by N
#   pb_finish          # completes bar
#   pb_wrap COMMAND... # runs command, auto tick, shows spinner state

# Internal state
__PB_TOTAL=0
__PB_CURRENT=0
__PB_WIDTH=40
__PB_START_TS=0
__PB_PREFIX=""
__PB_LAST_DRAW=0
__PB_MIN_INTERVAL=0.1  # seconds

pb_human_time() { # seconds -> H:MM:SS
  local s=$1 h m
  h=$((s/3600)); s=$((s%3600)); m=$((s/60)); s=$((s%60))
  if (( h > 0 )); then printf '%d:%02d:%02d' "$h" "$m" "$s"; else printf '%02d:%02d' "$m" "$s"; fi
}

pb_init() {
  __PB_TOTAL=${1:-0}
  __PB_PREFIX=${2:-}
  __PB_CURRENT=0
  __PB_START_TS=$(date +%s)
  __PB_LAST_DRAW=0
  pb_draw force
}

pb_percent() {
  if (( __PB_TOTAL <= 0 )); then echo 0; return; fi
  awk -v c="${__PB_CURRENT}" -v t="${__PB_TOTAL}" 'BEGIN { if (t<=0) print 0; else printf("%.0f", (c/t)*100) }'
}

pb_draw() {
  local now redraw pct filled blanks bar eta elapsed rate msg suffix
  now=$(date +%s%3N 2>/dev/null || date +%s) # ms if available
  # Rate limit drawing unless force
  if [[ ${1:-} != force ]]; then
    local diff
    diff=$(( now - __PB_LAST_DRAW ))
    # diff in ms when available
    if (( diff < 100 )); then return; fi
  fi
  __PB_LAST_DRAW=$now
  pct=$(pb_percent)
  if (( __PB_TOTAL > 0 )); then
    filled=$(( (__PB_WIDTH * __PB_CURRENT) / __PB_TOTAL ))
  else
    filled=$(( (__PB_WIDTH * (__PB_CURRENT%__PB_WIDTH)) / __PB_WIDTH ))
  fi
  (( filled > __PB_WIDTH )) && filled=$__PB_WIDTH
  blanks=$(( __PB_WIDTH - filled ))
  bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$blanks" '' | tr ' ' '-')"
  elapsed=$(( $(date +%s) - __PB_START_TS ))
  if (( __PB_CURRENT > 0 && __PB_TOTAL > 0 )); then
    local remaining avg
    avg=$(( elapsed / __PB_CURRENT ))
    remaining=$(( (__PB_TOTAL - __PB_CURRENT) * avg ))
    eta="~$(pb_human_time $remaining)"
  else
    eta="--:--"
  fi
  rate=""
  if (( elapsed > 0 && __PB_CURRENT > 0 )); then
    rate=" $(printf '%0.1f' "$(awk -v c=$__PB_CURRENT -v e=$elapsed 'BEGIN{ if (e>0) printf(c/e); else print 0 }')")/s"
  fi
  msg="${__PB_PREFIX}"
  suffix="${__PB_CURRENT}/${__PB_TOTAL} ${pct}% ETA ${eta}${rate}"
  printf '\r%s [%s] %s' "$msg" "$bar" "$suffix"
  if (( __PB_CURRENT >= __PB_TOTAL && __PB_TOTAL > 0 )); then
    printf '\n'
  fi
}

pb_add() { __PB_CURRENT=$(( __PB_CURRENT + ${1:-1} )); (( __PB_CURRENT > __PB_TOTAL )) && __PB_CURRENT=$__PB_TOTAL; pb_draw; }

pb_tick() { pb_add 1; }

pb_finish() { __PB_CURRENT=$__PB_TOTAL; pb_draw force; }

pb_wrap() {
  # If total unknown, set a spinner style progression
  local label=${1:-Task}; shift || true
  pb_init 1 "$label"
  "$@" && pb_finish || { printf '\n[progress] command failed: %s\n' "$*" >&2; return 1; }
}

# Convenience: run a sequence of package installations with a progress bar.
# pb_packages "Installing packages" pkg1 pkg2 ...
pb_packages() {
  local title="$1"; shift
  local pkgs=("$@")
  local count=${#pkgs[@]}
  (( count == 0 )) && return 0
  
  # Determine sudo command
  local sudo_cmd=""
  if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    sudo_cmd="sudo"
  fi
  
  pb_init "$count" "$title"
  for p in "${pkgs[@]}"; do
    if command -v apt-get >/dev/null 2>&1; then
      (${sudo_cmd:-} apt-get install -y "$p" >/dev/null 2>&1) || true
    elif command -v dnf >/dev/null 2>&1; then
      (${sudo_cmd:-} dnf install -y "$p" -q >/dev/null 2>&1) || true
    fi
    pb_tick
  done
  pb_finish
}

# Backup utility functions
backup_file() {
  local file="$1"
  local backup_suffix="${2:-.bak.$(date +%Y%m%d%H%M%S)}"
  local sudo_cmd=""
  
  [[ ! -f "$file" ]] && return 0
  
  if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    sudo_cmd="sudo"
  fi
  
  ${sudo_cmd:-} cp "$file" "${file}${backup_suffix}" 2>/dev/null || {
    echo "Warning: Could not backup $file" >&2
    return 1
  }
}

restore_file() {
  local file="$1"
  local backup_file="$2"
  local sudo_cmd=""
  
  [[ ! -f "$backup_file" ]] && { echo "Error: Backup file $backup_file not found" >&2; return 1; }
  
  if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    sudo_cmd="sudo"
  fi
  
  ${sudo_cmd:-} cp "$backup_file" "$file" 2>/dev/null || {
    echo "Error: Could not restore $backup_file to $file" >&2
    return 1
  }
}

# Centralized logging functions
CRUCIBLE_LOG_DIR="${TMPDIR:-/tmp}/crucible-logs"
CRUCIBLE_LOG_FILE="${CRUCIBLE_LOG_DIR}/crucible-$(date +%Y%m%d).log"

ensure_log_dir() {
  [[ -d "$CRUCIBLE_LOG_DIR" ]] || mkdir -p "$CRUCIBLE_LOG_DIR" 2>/dev/null || true
}

crucible_log() {
  local level="$1"; shift
  local component="${CRUCIBLE_COMPONENT:-unknown}"
  local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  local message="$*"
  
  ensure_log_dir
  echo "[$timestamp] [$level] [$component] $message" >> "$CRUCIBLE_LOG_FILE" 2>/dev/null || true
}

log_info() { crucible_log "INFO" "$@"; }
log_warn() { crucible_log "WARN" "$@"; }
log_error() { crucible_log "ERROR" "$@"; }
log_debug() { crucible_log "DEBUG" "$@"; }

# Service validation functions
validate_service_running() {
  local service_name="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet "$service_name" 2>/dev/null
  else
    return 1
  fi
}

validate_service_enabled() {
  local service_name="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-enabled --quiet "$service_name" 2>/dev/null
  else
    return 1
  fi
}

validate_command() {
  local cmd="$1"
  local expected_pattern="${2:-.*}"
  local output
  
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "$cmd command not found"
    return 1
  fi
  
  output=$("$cmd" --version 2>&1 | head -n1) || {
    log_error "$cmd --version failed"
    return 1
  }
  
  if [[ "$output" =~ $expected_pattern ]]; then
    log_info "$cmd validation passed: $output"
    return 0
  else
    log_error "$cmd validation failed: $output (expected pattern: $expected_pattern)"
    return 1
  fi
}

validate_port_listening() {
  local port="$1"
  local host="${2:-127.0.0.1}"
  
  if command -v netstat >/dev/null 2>&1; then
    netstat -tuln 2>/dev/null | grep -q ":$port "
  elif command -v ss >/dev/null 2>&1; then
    ss -tuln 2>/dev/null | grep -q ":$port "
  else
    # Fallback using /proc/net/tcp
    [[ -r /proc/net/tcp ]] && grep -q ":$(printf '%04X' "$port")" /proc/net/tcp 2>/dev/null
  fi
}

health_check_summary() {
  local service="$1"; shift
  local checks_passed=0
  local checks_total=0
  
  log_info "Starting health check for $service"
  
  for check in "$@"; do
    ((checks_total++))
    if eval "$check"; then
      ((checks_passed++))
      gum style --foreground 82 "  ✓ $check"
    else
      gum style --foreground 196 "  ✗ $check"
    fi
  done
  
  if [[ $checks_passed -eq $checks_total ]]; then
    gum style --foreground 82 --bold "$service health check: $checks_passed/$checks_total passed"
    log_info "$service health check completed successfully ($checks_passed/$checks_total)"
    return 0
  else
    gum style --foreground 214 --bold "$service health check: $checks_passed/$checks_total passed"
    log_warn "$service health check completed with issues ($checks_passed/$checks_total)"
    return 1
  fi
}
