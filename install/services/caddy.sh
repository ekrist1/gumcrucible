#!/usr/bin/env bash
# Install Caddy web server with automatic HTTPS
# Modern alternative to Nginx with automatic SSL certificate management
# Supports Ubuntu/Debian and Fedora systems
set -euo pipefail

# Set component name for logging
export CRUCIBLE_COMPONENT="caddy"

PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"

if ! command -v gum >/dev/null 2>&1; then
  echo "[caddy][warn] gum not found; proceeding without fancy UI" >&2
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
  gum style --foreground 196 "[caddy][error] Cannot detect OS"
  exit 1
fi

already_installed() {
  command_exists caddy
}

install_ubuntu_debian() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Install prerequisites
  local prereq_packages=(debian-keyring debian-archive-keyring apt-transport-https curl)
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing prerequisites" "${prereq_packages[@]}"
  else
    gum spin --spinner line --title "Installing prerequisites" -- bash -c "${sudo_cmd:-} apt-get update >/dev/null 2>&1 && ${sudo_cmd:-} apt-get install -y ${prereq_packages[*]} >/dev/null 2>&1"
  fi

  # Add Caddy repository
  gum spin --spinner line --title "Adding Caddy official repository" -- bash -c "
    set -euo pipefail
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | ${sudo_cmd:-} gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg >/dev/null 2>&1
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | ${sudo_cmd:-} tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  "

  # Update package index
  gum spin --spinner line --title "Updating package index" -- bash -c "${sudo_cmd:-} apt-get update >/dev/null 2>&1"

  # Install Caddy
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing Caddy" caddy
  else
    gum spin --spinner line --title "Installing Caddy" -- bash -c "${sudo_cmd:-} apt-get install -y caddy >/dev/null 2>&1"
  fi
}

install_fedora_like() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Add Caddy repository for Fedora/RHEL
  gum spin --spinner line --title "Adding Caddy official repository" -- bash -c "
    set -euo pipefail
    ${sudo_cmd:-} dnf install -y 'dnf-command(copr)' >/dev/null 2>&1 || true
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/setup.rpm.sh' | ${sudo_cmd:-} bash >/dev/null 2>&1
  "

  # Update package metadata
  gum spin --spinner line --title "Updating package metadata" -- bash -c "${sudo_cmd:-} dnf makecache >/dev/null 2>&1"

  # Install Caddy
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing Caddy" caddy
  else
    gum spin --spinner line --title "Installing Caddy" -- bash -c "${sudo_cmd:-} dnf install -y caddy >/dev/null 2>&1"
  fi
}

enable_start_services() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Enable and start Caddy
  if systemctl list-unit-files | grep -q '^caddy\.service'; then
    gum spin --spinner line --title "Enabling and starting Caddy" -- bash -c "${sudo_cmd:-} systemctl enable --now caddy >/dev/null 2>&1"
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
      ${sudo_cmd:-} ufw allow 80/tcp >/dev/null 2>&1 || true
      ${sudo_cmd:-} ufw allow 443/tcp >/dev/null 2>&1 || true
    "
  fi
}

setup_caddy_directories() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Create Caddy configuration directories
  local caddy_dirs=(
    "/etc/caddy/conf.d"
    "/var/log/caddy"
    "/var/lib/caddy"
  )

  for dir in "${caddy_dirs[@]}"; do
    if [[ ! -d "$dir" ]]; then
      ${sudo_cmd:-} mkdir -p "$dir" >/dev/null 2>&1 || true
    fi
  done

  # Ensure Caddy user owns its directories
  if id caddy >/dev/null 2>&1; then
    ${sudo_cmd:-} chown -R caddy:caddy /var/lib/caddy /var/log/caddy >/dev/null 2>&1 || true
  fi

  # Create a minimal Caddyfile if it doesn't exist
  if [[ ! -f "/etc/caddy/Caddyfile" ]]; then
    cat <<'EOF' | ${sudo_cmd:-} tee /etc/caddy/Caddyfile >/dev/null
# Caddy configuration file
# Add your site configurations here or in /etc/caddy/conf.d/*.caddy

# Import all .caddy files from conf.d
import /etc/caddy/conf.d/*.caddy

# Default server (optional - remove if not needed)
:80 {
    respond "Caddy is running! Configure your sites in /etc/caddy/conf.d/"
}
EOF
  fi
}

validate_caddy_config() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Validate Caddy configuration
  if command_exists caddy; then
    gum spin --spinner line --title "Validating Caddy configuration" -- bash -c "${sudo_cmd:-} caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1"
  fi
}

print_versions() {
  if command_exists caddy; then
    caddy version 2>&1 | head -n1 | xargs -I{} gum style --foreground 212 --bold "Caddy: {}"
  fi
}

run_caddy_health_check() {
  if ! declare -f health_check_summary >/dev/null 2>&1; then
    if declare -f log_warn >/dev/null 2>&1; then
      log_warn "Health check functions not available, skipping validation"
    fi
    return 0
  fi

  local checks=(
    "validate_command caddy 'v[0-9]'"
    "validate_service_enabled caddy"
    "validate_service_running caddy"
    "test -f '/etc/caddy/Caddyfile'"
    "test -d '/etc/caddy/conf.d'"
    "test -d '/var/log/caddy'"
    "test -d '/var/lib/caddy'"
  )

  # Check if Caddy configuration is valid
  checks+=("caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1")

  # Check if Caddy is responding
  checks+=("curl -f http://localhost >/dev/null 2>&1 || echo 'Caddy not responding (normal if no sites configured)'")

  health_check_summary "Caddy" "${checks[@]}"
}

main() {
  if already_installed; then
    gum style --foreground 82 "Caddy already installed"
    enable_start_services
    print_versions
    run_caddy_health_check
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

  setup_caddy_directories
  enable_start_services
  configure_firewall
  validate_caddy_config

  # Summary
  print_versions
  gum style --foreground 82 --bold "Caddy installation complete!"
  gum style --faint "Next steps:"
  gum style --faint "• Configure sites in /etc/caddy/conf.d/ (use .caddy extension)"
  gum style --faint "• Edit main config: /etc/caddy/Caddyfile"
  gum style --faint "• Reload config: sudo caddy reload --config /etc/caddy/Caddyfile"
  gum style --faint "• Check status: sudo systemctl status caddy"
  gum style --faint "• Caddy automatically handles HTTPS with Let's Encrypt!"

  # Run health check
  run_caddy_health_check
}

main "$@"
