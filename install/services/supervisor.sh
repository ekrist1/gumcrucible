#!/usr/bin/env bash
# Install Supervisor process control system
# Used for managing Laravel queue workers and background processes
# Supports Ubuntu/Debian and Fedora systems
set -euo pipefail

# Set component name for logging
export CRUCIBLE_COMPONENT="supervisor"

PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"

if ! command -v gum >/dev/null 2>&1; then
  echo "[supervisor][warn] gum not found; proceeding without fancy UI" >&2
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
  gum style --foreground 196 "[supervisor][error] Cannot detect OS"
  exit 1
fi

already_installed() {
  command_exists supervisord && command_exists supervisorctl
}

install_ubuntu_debian() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Update package index
  gum spin --spinner line --title "Updating package index" -- bash -c "${sudo_cmd:-} apt-get update >/dev/null 2>&1"

  # Install Supervisor
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing Supervisor" supervisor
  else
    gum spin --spinner line --title "Installing Supervisor" -- bash -c "${sudo_cmd:-} apt-get install -y supervisor >/dev/null 2>&1"
  fi
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

  # Install Supervisor
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing Supervisor" supervisor
  else
    gum spin --spinner line --title "Installing Supervisor" -- bash -c "${sudo_cmd:-} dnf install -y supervisor >/dev/null 2>&1"
  fi
}

enable_start_services() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Enable and start Supervisor
  if systemctl list-unit-files | grep -q '^supervisord\.service'; then
    gum spin --spinner line --title "Enabling and starting Supervisor" -- bash -c "${sudo_cmd:-} systemctl enable --now supervisord >/dev/null 2>&1"
  elif systemctl list-unit-files | grep -q '^supervisor\.service'; then
    gum spin --spinner line --title "Enabling and starting Supervisor" -- bash -c "${sudo_cmd:-} systemctl enable --now supervisor >/dev/null 2>&1"
  fi
}

setup_supervisor_directories() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Create Supervisor configuration directories
  local supervisor_dirs=(
    "/etc/supervisor/conf.d"
    "/var/log/supervisor"
  )

  for dir in "${supervisor_dirs[@]}"; do
    if [[ ! -d "$dir" ]]; then
      ${sudo_cmd:-} mkdir -p "$dir" >/dev/null 2>&1 || true
    fi
  done

  # Ensure main config includes conf.d directory
  local supervisor_conf="/etc/supervisor/supervisord.conf"
  if [[ -f "$supervisor_conf" ]]; then
    if ! grep -q "files = /etc/supervisor/conf.d/\*\.conf" "$supervisor_conf" 2>/dev/null; then
      gum spin --spinner line --title "Configuring Supervisor to include conf.d" -- bash -c "
        if ! grep -q '\[include\]' '$supervisor_conf'; then
          echo -e '\n[include]\nfiles = /etc/supervisor/conf.d/*.conf' | ${sudo_cmd:-} tee -a '$supervisor_conf' >/dev/null
        fi
      "
    fi
  fi
}

print_versions() {
  if command_exists supervisord; then
    supervisord --version 2>&1 | head -n1 | xargs -I{} gum style --foreground 212 --bold "Supervisor: {}"
  fi
}

run_supervisor_health_check() {
  if ! declare -f health_check_summary >/dev/null 2>&1; then
    if declare -f log_warn >/dev/null 2>&1; then
      log_warn "Health check functions not available, skipping validation"
    fi
    return 0
  fi

  local checks=(
    "validate_command supervisord 'supervisord'"
    "validate_command supervisorctl 'supervisorctl'"
    "test -f '/etc/supervisor/supervisord.conf'"
    "test -d '/etc/supervisor/conf.d'"
    "test -d '/var/log/supervisor'"
  )

  # Check if supervisord service is enabled and running
  if systemctl list-unit-files | grep -q '^supervisord\.service'; then
    checks+=(
      "validate_service_enabled supervisord"
      "validate_service_running supervisord"
    )
  elif systemctl list-unit-files | grep -q '^supervisor\.service'; then
    checks+=(
      "validate_service_enabled supervisor"
      "validate_service_running supervisor"
    )
  fi

  health_check_summary "Supervisor" "${checks[@]}"
}

main() {
  if already_installed; then
    gum style --foreground 82 "Supervisor already installed"
    enable_start_services
    print_versions
    run_supervisor_health_check
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

  setup_supervisor_directories
  enable_start_services

  # Summary
  print_versions
  gum style --foreground 82 --bold "Supervisor installation complete!"
  gum style --faint "Next steps:"
  gum style --faint "• Add program configurations in /etc/supervisor/conf.d/"
  gum style --faint "• Use 'supervisorctl reread' to reload configurations"
  gum style --faint "• Use 'supervisorctl update' to apply changes"
  gum style --faint "• Use 'supervisorctl status' to check running programs"

  # Run health check
  run_supervisor_health_check
}

main "$@"
