#!/usr/bin/env bash
# Install FrankenPHP - modern PHP application server built on Caddy
# Native support for Laravel Octane, automatic HTTPS, and worker mode
# No PHP-FPM required - serves PHP applications directly
set -euo pipefail

# Set component name for logging
export CRUCIBLE_COMPONENT="frankenphp"

PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"

if ! command -v gum >/dev/null 2>&1; then
  echo "[frankenphp][warn] gum not found; proceeding without fancy UI" >&2
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
  gum style --foreground 196 "[frankenphp][error] Cannot detect OS"
  exit 1
fi

already_installed() {
  command_exists frankenphp
}

# Detect system architecture
detect_architecture() {
  local arch
  arch=$(uname -m)

  case "$arch" in
    x86_64|amd64)
      echo "x86_64"
      ;;
    aarch64|arm64)
      echo "aarch64"
      ;;
    *)
      gum style --foreground 196 "Unsupported architecture: $arch"
      gum style --faint "FrankenPHP supports: x86_64, aarch64"
      exit 2
      ;;
  esac
}

install_prerequisites() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Check if PHP is installed (required for FrankenPHP to work)
  if ! command_exists php; then
    gum style --foreground 196 --bold "WARNING: PHP is not installed"
    gum style --faint "FrankenPHP includes PHP, but you may need PHP CLI for Composer and Artisan commands"
    if gum confirm "Install PHP anyway? (Recommended)"; then
      local php_script="${SCRIPT_DIR}/services/php84.sh"
      if [[ -f "$php_script" ]]; then
        bash "$php_script"
      else
        gum style --foreground 214 "Could not find PHP installer, continuing without PHP CLI"
      fi
    fi
  fi

  # Install required dependencies
  case "$DIST_ID" in
    ubuntu|debian)
      local prereq_packages=(curl ca-certificates)
      if declare -f pb_packages >/dev/null 2>&1; then
        pb_packages "Installing prerequisites" "${prereq_packages[@]}"
      else
        gum spin --spinner line --title "Installing prerequisites" -- bash -c "${sudo_cmd:-} apt-get update >/dev/null 2>&1 && ${sudo_cmd:-} apt-get install -y ${prereq_packages[*]} >/dev/null 2>&1"
      fi
      ;;
    fedora|centos|rhel)
      local prereq_packages=(curl ca-certificates)
      if declare -f pb_packages >/dev/null 2>&1; then
        pb_packages "Installing prerequisites" "${prereq_packages[@]}"
      else
        gum spin --spinner line --title "Installing prerequisites" -- bash -c "${sudo_cmd:-} dnf install -y ${prereq_packages[*]} >/dev/null 2>&1"
      fi
      ;;
  esac
}

download_frankenphp() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  local arch
  arch=$(detect_architecture)

  # Get latest release version from GitHub
  local version
  gum spin --spinner line --title "Detecting latest FrankenPHP version" -- bash -c "
    version=\$(curl -sL https://api.github.com/repos/dunglas/frankenphp/releases/latest | grep '\"tag_name\":' | sed -E 's/.*\"([^\"]+)\".*/\1/')
    echo \"\$version\"
  " > /tmp/frankenphp_version.tmp

  version=$(cat /tmp/frankenphp_version.tmp)
  rm -f /tmp/frankenphp_version.tmp

  if [[ -z "$version" ]]; then
    version="v1.0.0"  # Fallback version
    if declare -f log_warn >/dev/null 2>&1; then
      log_warn "Could not detect latest version, using fallback: $version"
    fi
  fi

  if declare -f log_info >/dev/null 2>&1; then
    log_info "Downloading FrankenPHP $version for $arch"
  fi

  # Determine download URL based on architecture
  local download_url
  if [[ "$arch" == "x86_64" ]]; then
    download_url="https://github.com/dunglas/frankenphp/releases/download/${version}/frankenphp-linux-x86_64"
  else
    download_url="https://github.com/dunglas/frankenphp/releases/download/${version}/frankenphp-linux-aarch64"
  fi

  # Download FrankenPHP binary
  gum spin --spinner line --title "Downloading FrankenPHP binary" -- bash -c "
    curl -L '$download_url' -o /tmp/frankenphp >/dev/null 2>&1
    ${sudo_cmd:-} install -m 755 /tmp/frankenphp /usr/local/bin/frankenphp
    rm -f /tmp/frankenphp
  "
}

create_frankenphp_user() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Create frankenphp user if it doesn't exist
  if ! id frankenphp >/dev/null 2>&1; then
    gum spin --spinner line --title "Creating frankenphp user" -- bash -c "
      ${sudo_cmd:-} useradd -r -d /var/lib/frankenphp -s /sbin/nologin -U frankenphp >/dev/null 2>&1 || true
    "
  fi
}

setup_frankenphp_directories() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Create FrankenPHP directories
  local frankenphp_dirs=(
    "/etc/frankenphp"
    "/etc/frankenphp/conf.d"
    "/var/log/frankenphp"
    "/var/lib/frankenphp"
  )

  for dir in "${frankenphp_dirs[@]}"; do
    if [[ ! -d "$dir" ]]; then
      ${sudo_cmd:-} mkdir -p "$dir" >/dev/null 2>&1 || true
    fi
  done

  # Set ownership
  if id frankenphp >/dev/null 2>&1; then
    ${sudo_cmd:-} chown -R frankenphp:frankenphp /var/lib/frankenphp /var/log/frankenphp >/dev/null 2>&1 || true
  fi

  # Create a minimal Caddyfile for FrankenPHP
  if [[ ! -f "/etc/frankenphp/Caddyfile" ]]; then
    cat <<'EOF' | ${sudo_cmd:-} tee /etc/frankenphp/Caddyfile >/dev/null
# FrankenPHP configuration file
# Add your site configurations here or in /etc/frankenphp/conf.d/*.caddy

# Import all .caddy files from conf.d
import /etc/frankenphp/conf.d/*.caddy

# Default server (optional - remove if not needed)
:80 {
    respond "FrankenPHP is running! Configure your sites in /etc/frankenphp/conf.d/"
}
EOF
  fi
}

create_systemd_service() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  if declare -f log_info >/dev/null 2>&1; then
    log_info "Creating systemd service for FrankenPHP"
  fi

  # Create systemd service file
  cat <<'EOF' | ${sudo_cmd:-} tee /etc/systemd/system/frankenphp.service >/dev/null
[Unit]
Description=FrankenPHP - Modern PHP Application Server
Documentation=https://frankenphp.dev/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=frankenphp
Group=frankenphp
ExecStart=/usr/local/bin/frankenphp run --config /etc/frankenphp/Caddyfile
ExecReload=/usr/local/bin/frankenphp reload --config /etc/frankenphp/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  # Reload systemd
  ${sudo_cmd:-} systemctl daemon-reload >/dev/null 2>&1
}

enable_start_services() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Enable and start FrankenPHP
  if systemctl list-unit-files | grep -q '^frankenphp\.service'; then
    gum spin --spinner line --title "Enabling and starting FrankenPHP" -- bash -c "${sudo_cmd:-} systemctl enable --now frankenphp >/dev/null 2>&1"
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

print_versions() {
  if command_exists frankenphp; then
    frankenphp version 2>&1 | head -n1 | xargs -I{} gum style --foreground 212 --bold "FrankenPHP: {}"
  fi
}

run_frankenphp_health_check() {
  if ! declare -f health_check_summary >/dev/null 2>&1; then
    if declare -f log_warn >/dev/null 2>&1; then
      log_warn "Health check functions not available, skipping validation"
    fi
    return 0
  fi

  local checks=(
    "validate_command frankenphp 'FrankenPHP|v[0-9]'"
    "validate_service_enabled frankenphp"
    "validate_service_running frankenphp"
    "test -f '/etc/frankenphp/Caddyfile'"
    "test -d '/etc/frankenphp/conf.d'"
    "test -d '/var/log/frankenphp'"
    "test -d '/var/lib/frankenphp'"
    "test -f '/usr/local/bin/frankenphp'"
  )

  # Check if FrankenPHP is responding
  checks+=("curl -f http://localhost >/dev/null 2>&1 || echo 'FrankenPHP not responding (normal if no sites configured)'")

  health_check_summary "FrankenPHP" "${checks[@]}"
}

main() {
  if already_installed; then
    gum style --foreground 82 "FrankenPHP already installed"
    enable_start_services
    print_versions
    run_frankenphp_health_check
    exit 0
  fi

  install_prerequisites
  download_frankenphp
  create_frankenphp_user
  setup_frankenphp_directories
  create_systemd_service
  enable_start_services
  configure_firewall

  # Summary
  print_versions
  gum style --foreground 82 --bold "FrankenPHP installation complete!"
  gum style --faint "Next steps:"
  gum style --faint "• Configure sites in /etc/frankenphp/conf.d/ (use .caddy extension)"
  gum style --faint "• Edit main config: /etc/frankenphp/Caddyfile"
  gum style --faint "• Reload config: sudo frankenphp reload --config /etc/frankenphp/Caddyfile"
  gum style --faint "• Check status: sudo systemctl status frankenphp"
  gum style --faint "• View logs: sudo journalctl -u frankenphp -f"
  echo
  gum style --foreground 212 --bold "✨ FrankenPHP Features:"
  gum style --faint "• Native Laravel Octane support (no extra setup needed!)"
  gum style --faint "• Automatic HTTPS with Let's Encrypt"
  gum style --faint "• Worker mode for improved performance"
  gum style --faint "• HTTP/2 and HTTP/3 support"
  gum style --faint "• No PHP-FPM required"

  # Run health check
  run_frankenphp_health_check
}

main "$@"
