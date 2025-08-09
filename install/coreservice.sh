#!/usr/bin/env bash
# Core services orchestrator (php, caddy, mysql)
set -euo pipefail

clear || true

if ! command -v gum >/dev/null 2>&1; then
  echo "[coreservice][error] gum required" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detection helpers for checkmarks
command_exists() { command -v "$1" >/dev/null 2>&1; }

has_php84() {
  if command_exists php; then
    local ver
    ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    [[ "$ver" == "8.4" ]]
  else
    return 1
  fi
}

has_caddy() { command_exists caddy; }
has_composer() { command_exists composer; }
has_docker() { command_exists docker; }
has_mysql() {
  if command_exists mysql; then return 0; fi
  if command_exists systemctl && systemctl list-unit-files | grep -qE '^(mysql|mysqld|mariadb)\.service'; then return 0; fi
  return 1
}

install_php() {
  local php_script="${SCRIPT_DIR}/services/php84.sh"
  if [[ -f "$php_script" ]]; then
    bash "$php_script"
  else
    gum style --foreground 196 "Missing: services/php84.sh"
  fi
}

install_caddy() {
  local caddy_script="${SCRIPT_DIR}/services/caddy.sh"
  if [[ -f "$caddy_script" ]]; then
    bash "$caddy_script"
  else
    gum style --foreground 196 "Missing: services/caddy.sh"
  fi
}

install_mysql() {
  gum spin --spinner line --title "(placeholder) Installing MySQL" -- sleep 1
}

install_composer() {
  local composer_script="${SCRIPT_DIR}/services/composer.sh"
  if [[ -f "$composer_script" ]]; then
    bash "$composer_script"
  else
    gum style --foreground 196 "Missing: services/composer.sh"
  fi
}

install_docker() {
  local docker_script="${SCRIPT_DIR}/services/docker.sh"
  if [[ -f "$docker_script" ]]; then
    bash "$docker_script"
  else
    gum style --foreground 196 "Missing: services/docker.sh"
  fi
}

while true; do
  clear || true
  # Dynamic checkmarks
  mark_php=$(has_php84 && echo "[x]" || echo "[ ]")
  mark_caddy=$(has_caddy && echo "[x]" || echo "[ ]")
  mark_comp=$(has_composer && echo "[x]" || echo "[ ]")
  mark_docker=$(has_docker && echo "[x]" || echo "[ ]")
  mark_mysql=$(has_mysql && echo "[x]" || echo "[ ]")

  choice=$(gum choose --header "Core Services" \
    "${mark_php} Install PHP 8.4" \
    "${mark_caddy} Install Caddy" \
    "${mark_comp} Install Composer" \
    "${mark_docker} Install Docker & Compose" \
    "${mark_mysql} Install MySQL" \
    "Install All" \
    "Back") || exit 0
  case "$choice" in
    *"Install PHP 8.4"*) install_php ;;
  *"Install Caddy"*) install_caddy ;;
  *"Install Composer"*) install_composer ;;
  *"Install Docker & Compose"*) install_docker ;;
  *"Install MySQL"*) install_mysql ;;
  "Install All") install_php; install_caddy; install_composer; install_docker; install_mysql ;;
    Back) break ;;
  esac
  gum confirm "Another core service action?" || break
done

gum style --foreground 82 --bold "Core services menu complete."
