#!/usr/bin/env bash
# Framework installer (Laravel, Next.js)
set -euo pipefail

clear || true

if ! command -v gum >/dev/null 2>&1; then
  echo "[framework][error] gum required" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detection helpers for checkmarks
command_exists() { command -v "$1" >/dev/null 2>&1; }

has_laravel_caddy() {
  # Check if caddy_laravel script exists
  [[ -f "${SCRIPT_DIR}/frameworks/caddy_laravel.sh" ]]
}

has_laravel_nginx() {
  # Check if laravel_nginx script exists and nginx is installed
  [[ -f "${SCRIPT_DIR}/frameworks/laravel_nginx.sh" ]] && command_exists nginx
}

has_next_nginx() {
  [[ -f "${SCRIPT_DIR}/frameworks/nextjs_nginx.sh" ]] && command_exists nginx
}

launch_script() {
  local script="$1"
  local target="${SCRIPT_DIR}/frameworks/${script}"
  if [[ -x "$target" ]]; then
    "$target"
  elif [[ -f "$target" ]]; then
    bash "$target"
  else
    gum style --foreground 196 "Missing script: frameworks/${script}"
    return 1
  fi
}

while true; do
  clear || true
  
  # Dynamic checkmarks
  mark_caddy=$(has_laravel_caddy && echo "[✓]" || echo "[ ]")
  mark_nginx=$(has_laravel_nginx && echo "[✓]" || echo "[!]")
  mark_next=$(has_next_nginx && echo "[✓]" || echo "[!]")
  
  CHOICE=$(gum choose --header "Framework Installation" \
    "${mark_caddy} Laravel + Caddy" \
    "${mark_nginx} Laravel + Nginx" \
    "${mark_next} Next.js + Nginx" \
    "Back") || exit 0
  
  case "$CHOICE" in
    *"Laravel + Caddy"*)
      gum style --foreground 45 --bold "Launching Laravel + Caddy installer"
      launch_script "caddy_laravel.sh" || true
      ;;
    *"Laravel + Nginx"*)
      if ! command_exists nginx; then
        gum style --foreground 196 --bold "Nginx is required for Laravel + Nginx installation"
        gum style --faint "Install Nginx first through Core Services menu"
        gum confirm "Continue anyway?" || continue
      fi
      gum style --foreground 45 --bold "Launching Laravel + Nginx installer"
      launch_script "laravel_nginx.sh" || true
      ;;
    *"Next.js + Nginx"*)
      if ! command_exists nginx; then
        gum style --foreground 196 --bold "Nginx is required for Next.js + Nginx installation"
        gum style --faint "Install Nginx first through Core Services menu"
        gum confirm "Continue anyway?" || continue
      fi
      gum style --foreground 45 --bold "Launching Next.js + Nginx installer"
      launch_script "nextjs_nginx.sh" || true
      ;;
    "Back")
      break
      ;;
  esac
  
  echo
  gum confirm "Install another framework?" || break
  echo
done

gum style --foreground 82 --bold "Framework menu complete."
