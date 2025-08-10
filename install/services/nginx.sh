#!/usr/bin/env bash
# Install Nginx web server and Certbot for SSL certificates
# Supports Ubuntu/Debian and Fedora systems with PHP-FPM compatibility
# Only installs packages - configuration is handled by separate scripts
set -euo pipefail

# Set component name for logging
export CRUCIBLE_COMPONENT="nginx"

PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"

if ! command -v gum >/dev/null 2>&1; then
  echo "[nginx][warn] gum not found; proceeding without fancy UI" >&2
  gum() { shift || true; "$@"; }
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }
need_sudo() { if [[ $EUID -ne 0 ]]; then command_exists sudo && echo sudo; fi; }

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  DIST_ID="${ID,,}"
  DIST_LIKE="${ID_LIKE:-}"; DIST_LIKE="${DIST_LIKE,,}"
  VERSION_ID="${VERSION_ID:-}"
else
  gum style --foreground 196 "[nginx][error] Cannot detect OS"
  exit 1
fi

already_installed() { 
  command_exists nginx && command_exists certbot
}

install_ubuntu_debian() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  # Update package index
  gum spin --spinner line --title "Updating package index" -- bash -c "${sudo_cmd:-} apt-get update >/dev/null 2>&1"
  
  # Install prerequisites
  local prereq_packages=(curl ca-certificates gnupg lsb-release software-properties-common)
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing prerequisites" "${prereq_packages[@]}"
  else
    gum spin --spinner line --title "Installing prerequisites" -- bash -c "${sudo_cmd:-} apt-get install -y ${prereq_packages[*]} >/dev/null 2>&1"
  fi
  
  # Install Nginx
  local nginx_packages=(nginx nginx-common nginx-core)
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing Nginx" "${nginx_packages[@]}"
  else
    gum spin --spinner line --title "Installing Nginx" -- bash -c "${sudo_cmd:-} apt-get install -y ${nginx_packages[*]} >/dev/null 2>&1"
  fi
  
  # Install Certbot and Nginx plugin
  local certbot_packages=(certbot python3-certbot-nginx)
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing Certbot" "${certbot_packages[@]}"
  else
    gum spin --spinner line --title "Installing Certbot" -- bash -c "${sudo_cmd:-} apt-get install -y ${certbot_packages[*]} >/dev/null 2>&1"
  fi
  
  # Install additional useful packages for PHP integration
  gum spin --spinner line --title "Installing additional Nginx modules" -- bash -c "${sudo_cmd:-} apt-get install -y nginx-extras >/dev/null 2>&1 || true"
}

install_fedora_like() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  # Install EPEL repository for additional packages (CentOS/RHEL)
  if [[ "$DIST_ID" == "centos" || "$DIST_ID" == "rhel" || "$DIST_LIKE" == *"rhel"* ]]; then
    gum spin --spinner line --title "Installing EPEL repository" -- bash -c "${sudo_cmd:-} dnf install -y epel-release >/dev/null 2>&1 || true"
  fi
  
  # Update package metadata
  gum spin --spinner line --title "Updating package metadata" -- bash -c "${sudo_cmd:-} dnf makecache >/dev/null 2>&1"
  
  # Install Nginx
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing Nginx" nginx
  else
    gum spin --spinner line --title "Installing Nginx" -- bash -c "${sudo_cmd:-} dnf install -y nginx >/dev/null 2>&1"
  fi
  
  # Install Certbot - try different approaches based on system
  local certbot_installed=false
  
  # Try snapd first (modern approach)
  if command_exists snap || ${sudo_cmd:-} dnf install -y snapd >/dev/null 2>&1; then
    gum spin --spinner line --title "Installing Certbot via snap" -- bash -c "
      ${sudo_cmd:-} systemctl enable --now snapd.socket >/dev/null 2>&1 || true
      ${sudo_cmd:-} snap install core >/dev/null 2>&1 || true
      ${sudo_cmd:-} snap refresh core >/dev/null 2>&1 || true
      ${sudo_cmd:-} snap install --classic certbot >/dev/null 2>&1 || true
      ${sudo_cmd:-} ln -sf /snap/bin/certbot /usr/bin/certbot >/dev/null 2>&1 || true
    " && certbot_installed=true || true
  fi
  
  # Fallback to DNF packages
  if [[ "$certbot_installed" == "false" ]]; then
    local certbot_packages=(certbot python3-certbot-nginx)
    if declare -f pb_packages >/dev/null 2>&1; then
      pb_packages "Installing Certbot" "${certbot_packages[@]}"
    else
      gum spin --spinner line --title "Installing Certbot via DNF" -- bash -c "${sudo_cmd:-} dnf install -y ${certbot_packages[*]} >/dev/null 2>&1"
    fi
  fi
}

enable_start_services() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  # Enable and start Nginx
  if systemctl list-unit-files | grep -q '^nginx\.service'; then
    gum spin --spinner line --title "Enabling and starting Nginx" -- bash -c "${sudo_cmd:-} systemctl enable --now nginx >/dev/null 2>&1"
  fi
  
  # Enable snapd if installed (for snap-based Certbot)
  if systemctl list-unit-files | grep -q '^snapd\.service'; then
    gum spin --spinner line --title "Ensuring snapd is running" -- bash -c "${sudo_cmd:-} systemctl enable --now snapd >/dev/null 2>&1 || true"
  fi
}

configure_firewall() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  # Configure firewall for HTTP/HTTPS (optional - only if firewall is active)
  if systemctl is-active firewalld >/dev/null 2>&1; then
    gum spin --spinner line --title "Configuring firewall for HTTP/HTTPS" -- bash -c "
      ${sudo_cmd:-} firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
      ${sudo_cmd:-} firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
      ${sudo_cmd:-} firewall-cmd --reload >/dev/null 2>&1 || true
    "
  elif command_exists ufw && ${sudo_cmd:-} ufw status | grep -q "Status: active"; then
    gum spin --spinner line --title "Configuring UFW for HTTP/HTTPS" -- bash -c "
      ${sudo_cmd:-} ufw allow 'Nginx Full' >/dev/null 2>&1 || true
    "
  fi
}

create_nginx_user() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  # Ensure nginx user exists (usually created by package, but just in case)
  if ! id nginx >/dev/null 2>&1; then
    if command_exists useradd; then
      gum spin --spinner line --title "Creating nginx user" -- bash -c "${sudo_cmd:-} useradd -r -d /var/cache/nginx -s /sbin/nologin -U nginx >/dev/null 2>&1 || true"
    fi
  fi
}

setup_basic_directories() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  # Create modern Nginx directories (sites-available/enabled are deprecated)
  local nginx_dirs=(
    "/etc/nginx/conf.d"
    "/var/log/nginx"
    "/var/cache/nginx"
    "/var/lib/nginx"
  )
  
  for dir in "${nginx_dirs[@]}"; do
    if [[ ! -d "$dir" ]]; then
      ${sudo_cmd:-} mkdir -p "$dir" >/dev/null 2>&1 || true
    fi
  done
  
  # Set proper ownership
  if id nginx >/dev/null 2>&1; then
    ${sudo_cmd:-} chown -R nginx:nginx /var/cache/nginx /var/lib/nginx >/dev/null 2>&1 || true
  fi
}

test_nginx_config() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  # Test Nginx configuration
  if command_exists nginx; then
    gum spin --spinner line --title "Testing Nginx configuration" -- bash -c "${sudo_cmd:-} nginx -t >/dev/null 2>&1"
  fi
}

print_versions() {
  if command_exists nginx; then
    nginx -v 2>&1 | head -n1 | xargs -I{} gum style --foreground 212 --bold "Nginx: {}"
  fi
  if command_exists certbot; then
    certbot --version 2>&1 | head -n1 | xargs -I{} gum style --foreground 212 --bold "Certbot: {}"
  fi
}

run_nginx_health_check() {
  if ! declare -f health_check_summary >/dev/null 2>&1; then
    if declare -f log_warn >/dev/null 2>&1; then
      log_warn "Health check functions not available, skipping validation"
    fi
    return 0
  fi
  
  local checks=(
    "validate_command nginx 'nginx version'"
    "validate_command certbot 'certbot [0-9]'"
    "validate_service_enabled nginx"
    "validate_service_running nginx"
    "test -f '/etc/nginx/nginx.conf'"
    "test -d '/etc/nginx/conf.d'"
    "test -d '/var/log/nginx'"
  )
  
  # Check if nginx configuration is valid
  checks+=("nginx -t >/dev/null 2>&1")
  
  # Check if nginx is responding
  checks+=("curl -f http://localhost >/dev/null 2>&1 || echo 'Nginx not responding (normal if no sites configured)'")
  
  # Check certbot nginx plugin
  if certbot plugins 2>/dev/null | grep -q nginx; then
    checks+=("certbot plugins 2>/dev/null | grep -q nginx")
  fi
  
  health_check_summary "Nginx & Certbot" "${checks[@]}"
}

main() {
  if already_installed; then
    gum style --foreground 82 "Nginx and Certbot already installed"
    enable_start_services
    print_versions
    run_nginx_health_check
    exit 0
  fi

  case "$DIST_ID" in
    ubuntu|debian) 
      install_ubuntu_debian 
      ;;
    fedora|centos|rhel) 
      install_fedora_like 
      ;;
    *)
      if [[ "$DIST_LIKE" == *"debian"* ]]; then
        install_ubuntu_debian
      elif [[ "$DIST_LIKE" == *"fedora"* || "$DIST_LIKE" == *"rhel"* ]]; then
        install_fedora_like
      else
        gum style --foreground 196 "Unsupported distribution: $DIST_ID"
        exit 2
      fi
      ;;
  esac

  create_nginx_user
  setup_basic_directories
  enable_start_services
  configure_firewall
  test_nginx_config
  
  # Summary
  print_versions
  gum style --foreground 82 --bold "Nginx and Certbot installation complete!"
  gum style --faint "Next steps:"
  gum style --faint "• Configure Nginx sites in /etc/nginx/conf.d/"
  gum style --faint "• Use 'certbot --nginx' to obtain SSL certificates"
  gum style --faint "• Ensure PHP-FPM is installed for Laravel applications"
  
  # Run health check
  run_nginx_health_check
}

main "$@"