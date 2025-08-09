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
  pb_init "$count" "$title"
  for p in "${pkgs[@]}"; do
    if command -v apt-get >/dev/null 2>&1; then
      (apt-get install -y "$p" >/dev/null 2>&1) || true
    elif command -v dnf >/dev/null 2>&1; then
      (dnf install -y "$p" -q >/dev/null 2>&1) || true
    fi
    pb_tick
  done
  pb_finish
}
