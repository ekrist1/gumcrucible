#!/usr/bin/env bash
# Crucible startup menu using gum
set -euo pipefail

banner() {
  clear || true
  cat <<'EOF'


  _____                 _ _     _      
 / ____|               (_) |   | |     
| |     _ __ _   _  ___ _| |__ | | ___ 
| |    | '__| | | |/ __| | '_ \| |/ _ \
| |____| |  | |_| | (__| | |_) | |  __/
 \_____|_|   \__,_|\___|_|_.__/|_|\___|


EOF
  echo
}

banner

if ! command -v gum >/dev/null 2>&1; then
  echo "[crucible][error] gum not found. Run install.sh first." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

launch_script() {
  local script="$1"
  local target="${SCRIPT_DIR}/install/${script}"
  if [[ -x "$target" ]]; then
    "$target"
  elif [[ -f "$target" ]]; then
    bash "$target"
  else
    gum style --foreground 196 "Missing script: install/${script}"
    return 1
  fi
}

main_menu() {
  banner
  local choice
  choice=$(gum choose --header "Crucible Startup Menu" \
    "Core services (php, caddy, mysql)" \
  "Framework (Laravel, Next)" \
  "Deploy Laravel Application" \
  "Configure Laravel Environment (.env)" \
  "Docker Management" \
    "Exit") || exit 0

  case "$choice" in
    "Core services (php, caddy, mysql)")
      gum style --foreground 212 --bold "Launching Core Services installer"
      launch_script coreservice.sh || true
      ;;
    "Framework (Laravel, Next)")
      gum style --foreground 45 --bold "Launching Framework installer"
      launch_script framework.sh || true
      ;;
    "Deploy Laravel Application")
      gum style --foreground 82 --bold "Launching Laravel Deployment"
      launch_script operation/deploy_laravel.sh || true
      ;;
    "Configure Laravel Environment (.env)")
      gum style --foreground 214 --bold "Launching Environment Configuration"
      launch_script operation/configure_env.sh || true
      ;;
    "Docker Management")
      gum style --foreground 39 --bold "Opening Docker Management"
      launch_script operation/docker.sh || true
      ;;
    Exit)
      echo "Bye"; exit 0 ;;
  esac
}

while true; do
  main_menu
  echo
  gum confirm "Return to main menu?" || break
  echo
done

echo "[crucible] Finished."
