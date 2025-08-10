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

has_composer() { command_exists composer; }
has_docker() { command_exists docker; }
has_caddy() { command_exists caddy; }
has_nginx() { command_exists nginx; }
has_mcert() { command_exists mkcert; }
has_node() {
  command_exists node && command_exists npm
}
has_mysql() {
  # Check for mysql/mariadb client
  if command_exists mysql || command_exists mariadb; then return 0; fi
  # Check for running services
  if command_exists systemctl; then
    if systemctl list-unit-files 2>/dev/null | grep -qE '^(mysql|mysqld|mariadb)\.service'; then return 0; fi
    if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then return 0; fi
  fi
  # Check for common server binaries
  if command_exists mysqld || command_exists mariadbd; then return 0; fi
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

install_mysql() {
  local mysql_script="${SCRIPT_DIR}/services/mysql.sh"
  if [[ -f "$mysql_script" ]]; then
    bash "$mysql_script"
  else
    gum style --foreground 196 "Missing: services/mysql.sh"
  fi
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

install_caddy() {
  gum spin --spinner line --title "(placeholder) Installing Caddy" -- sleep 1
}

install_nginx() {
  local nginx_script="${SCRIPT_DIR}/services/nginx.sh"
  if [[ -f "$nginx_script" ]]; then
    bash "$nginx_script"
  else
    gum style --foreground 196 "Missing: services/nginx.sh"
  fi
}

install_mcert() {
  local mcert_script="${SCRIPT_DIR}/services/mcert.sh"
  if [[ -f "$mcert_script" ]]; then
    bash "$mcert_script"
  else
    gum style --foreground 196 "Missing: services/mcert.sh"
  fi
}

install_node() {
  local node_script="${SCRIPT_DIR}/services/node.sh"
  if [[ -f "$node_script" ]]; then
    bash "$node_script"
  else
    gum style --foreground 196 "Missing: services/node.sh"
  fi
}

while true; do
  clear || true
  # Dynamic checkmarks
  mark_php=$(has_php84 && echo "[x]" || echo "[ ]")
  mark_comp=$(has_composer && echo "[x]" || echo "[ ]")
  mark_docker=$(has_docker && echo "[x]" || echo "[ ]")
  mark_caddy=$(has_caddy && echo "[x]" || echo "[ ]")
  mark_nginx=$(has_nginx && echo "[x]" || echo "[ ]")
  mark_mcert=$(has_mcert && echo "[x]" || echo "[ ]")
  mark_node=$(has_node && echo "[x]" || echo "[ ]")
  mark_mysql=$(has_mysql && echo "[x]" || echo "[ ]")

  choice=$(gum choose --header "Core Services" \
    "${mark_php} Install PHP 8.4" \
    "${mark_comp} Install Composer" \
    "${mark_caddy} Install Caddy" \
    "${mark_nginx} Install Nginx & Certbot" \
    "${mark_mcert} mcert - local development cert" \
    "${mark_node} Install Node & NPM (optional PM2)" \
    "${mark_docker} Install Docker & Compose" \
    "${mark_mysql} Install MySQL" \
    "Install All" \
    "Back") || exit 0
  case "$choice" in
    *"Install PHP 8.4"*) install_php ;;
    *"Install Composer"*) install_composer ;;
    *"Install Caddy"*) install_caddy ;;
    *"Install Nginx & Certbot"*) install_nginx ;;
  *"mcert - local development cert"*) install_mcert ;;
  *"Install Node & NPM (optional PM2)"*) install_node ;;
    *"Install Docker & Compose"*) install_docker ;;
    *"Install MySQL"*) install_mysql ;;
  "Install All") install_php; install_composer; install_caddy; install_nginx; install_mcert; install_node; install_docker; install_mysql ;;
    Back) break ;;
  esac
  gum confirm "Another core service action?" || break
done

gum style --foreground 82 --bold "Core services menu complete."
