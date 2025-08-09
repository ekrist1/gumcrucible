#!/usr/bin/env bash
# Placeholder framework installer (Laravel, Next)
set -euo pipefail

clear || true

if ! command -v gum >/dev/null 2>&1; then
  echo "[framework][error] gum required" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CHOICE=$(gum choose --header "Select framework" \
  "Laravel" \
  "Prepare Caddy for Laravel" \
  "Next" \
  "Cancel") || exit 0
case "$CHOICE" in
  Laravel)
    gum spin --spinner pulse --title "(placeholder) Setting up Laravel" -- sleep 2
    gum style --foreground 82 "Laravel placeholder done."
    ;;
  "Prepare Caddy for Laravel")
    script_laravel="${SCRIPT_DIR}/frameworks/caddy_laravel.sh"
    if [[ -f "$script_laravel" ]]; then
      bash "$script_laravel"
    else
      gum style --foreground 196 "Missing: frameworks/caddy_laravel.sh"
    fi
    ;;
  Next)
    gum spin --spinner pulse --title "(placeholder) Setting up Next.js" -- sleep 2
    gum style --foreground 82 "Next.js placeholder done."
    ;;
  Cancel)
    gum style --foreground 214 "Cancelled framework selection" ;;
 esac
