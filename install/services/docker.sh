#!/usr/bin/env bash
# Install Docker Engine, CLI, Buildx and Compose v2 plugin
# Supports Ubuntu/Debian and Fedora. Enables and starts docker service.
# No firewall or app config changes.
set -euo pipefail

# Set component name for logging
export CRUCIBLE_COMPONENT="docker"

PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"

if ! command -v gum >/dev/null 2>&1; then
  echo "[docker][warn] gum not found; proceeding without fancy UI" >&2
  gum() { shift || true; "$@"; }
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }
need_sudo() { if [[ $EUID -ne 0 ]]; then command_exists sudo && echo sudo; fi; }

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  DIST_ID="${ID,,}"
  DIST_LIKE="${ID_LIKE:-}"; DIST_LIKE="${DIST_LIKE,,}"
  VERSION_CODENAME="${VERSION_CODENAME:-}"
else
  gum style --foreground 196 "[docker][error] Cannot detect OS"; exit 1
fi

already_installed() { command_exists docker; }

install_ubuntu_debian() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  # Remove conflicting packages (comprehensive list per official docs)
  local old_packages=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc docker docker-engine)
  gum spin --spinner line --title "Removing conflicting packages" -- bash -c "
    for pkg in ${old_packages[*]}; do
      ${sudo_cmd:-} apt-get remove -y \$pkg >/dev/null 2>&1 || true
    done
  "

  # Prerequisites (update first, then install packages)
  gum spin --spinner line --title "Updating package index" -- bash -c "${sudo_cmd:-} apt-get update >/dev/null 2>&1"
  gum spin --spinner line --title "Installing prerequisites" -- bash -c "${sudo_cmd:-} apt-get install -y ca-certificates curl >/dev/null 2>&1"

  # Set up Docker GPG key (following official docs exactly)
  gum spin --spinner line --title "Setting up Docker GPG key" -- bash -c "
    ${sudo_cmd:-} install -m 0755 -d /etc/apt/keyrings
    ${sudo_cmd:-} curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    ${sudo_cmd:-} chmod a+r /etc/apt/keyrings/docker.asc
  "

  # Add Docker repository (with proper Ubuntu codename handling)
  local arch codename
  arch=$(dpkg --print-architecture)
  # Use UBUNTU_CODENAME if available, fallback to VERSION_CODENAME (as per official docs)
  if [[ -n "${UBUNTU_CODENAME:-}" ]]; then
    codename="$UBUNTU_CODENAME"
  else
    codename="$VERSION_CODENAME"
  fi
  
  gum spin --spinner line --title "Adding Docker repository" -- bash -c "
    echo \"deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable\" | ${sudo_cmd:-} tee /etc/apt/sources.list.d/docker.list >/dev/null
    ${sudo_cmd:-} apt-get update >/dev/null 2>&1
  "

  # Install Docker packages
  local pkgs=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing Docker Engine & Compose" "${pkgs[@]}"
  else
    gum spin --spinner line --title "Installing Docker Engine & Compose" -- bash -c "${sudo_cmd:-} apt-get install -y ${pkgs[*]} >/dev/null 2>&1"
  fi
}

install_fedora_like() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  # Remove old/conflicting packages (more comprehensive list)
  local old_packages=(docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine docker.io containerd runc podman-docker)
  gum spin --spinner line --title "Removing conflicting packages" -- bash -c "
    for pkg in ${old_packages[*]}; do
      ${sudo_cmd:-} dnf remove -y \$pkg >/dev/null 2>&1 || true
    done
  "

  # Install DNF plugins
  gum spin --spinner line --title "Installing DNF plugins" -- bash -c "${sudo_cmd:-} dnf install -y dnf-plugins-core >/dev/null 2>&1"

  # Add Docker repository (using correct dnf-3 command as per official docs)
  gum spin --spinner line --title "Adding Docker CE repository" -- bash -c "
    ${sudo_cmd:-} dnf-3 config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo >/dev/null 2>&1 || {
      # Fallback to regular dnf config-manager if dnf-3 doesn't exist
      ${sudo_cmd:-} dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo >/dev/null 2>&1
    }
  "

  # Refresh repository metadata
  gum spin --spinner line --title "Refreshing package metadata" -- bash -c "${sudo_cmd:-} dnf makecache >/dev/null 2>&1"

  # Install Docker packages
  local pkgs=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing Docker Engine & Compose" "${pkgs[@]}"
  else
    gum spin --spinner line --title "Installing Docker Engine & Compose" -- bash -c "${sudo_cmd:-} dnf install -y ${pkgs[*]} >/dev/null 2>&1"
  fi
}

enable_start_service() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  if command_exists systemctl && systemctl list-unit-files | grep -q '^docker\.service'; then
    # Use the official recommended command: enable --now (enables and starts in one command)
    gum spin --spinner line --title "Enabling and starting Docker service" -- bash -c "${sudo_cmd:-} systemctl enable --now docker >/dev/null 2>&1 || true"
  fi
}

configure_docker_group() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  # Only offer group configuration for non-root users
  if [[ $EUID -ne 0 ]]; then
    local current_user
    current_user=$(whoami)
    
    if ! groups "$current_user" | grep -q docker; then
      echo
      gum style --foreground 45 --bold "Docker Group Configuration"
      gum style --faint "To run Docker without sudo, your user needs to be in the docker group."
      gum style --faint "This allows non-root access to Docker daemon."
      
      if gum confirm "Add user '$current_user' to docker group?"; then
        gum spin --spinner line --title "Adding user to docker group" -- bash -c "${sudo_cmd:-} usermod -aG docker $current_user >/dev/null 2>&1"
        echo
        gum style --foreground 214 --bold "Important: You need to log out and back in for group changes to take effect!"
        gum style --faint "Or run: newgrp docker"
      else
        echo
        gum style --faint "You can add yourself to docker group later with:"
        gum style --faint "  sudo usermod -aG docker $current_user"
      fi
    fi
  fi
}

print_versions() {
  if command_exists docker; then
    docker --version 2>/dev/null | head -n1 | xargs -I{} gum style --foreground 212 --bold {}
  fi
  if docker compose version >/dev/null 2>&1; then
    docker compose version 2>/dev/null | head -n1 | xargs -I{} gum style --foreground 212 {}
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose --version 2>/dev/null | head -n1 | xargs -I{} gum style --foreground 212 {}
  fi
}

main() {
  if already_installed; then
    gum style --foreground 82 "Docker already installed"
    enable_start_service
    print_versions
    exit 0
  fi

  case "$DIST_ID" in
    ubuntu|debian) install_ubuntu_debian ;;
    fedora) install_fedora_like ;;
    *)
      if [[ "$DIST_LIKE" == *"debian"* ]]; then
        install_ubuntu_debian
      elif [[ "$DIST_LIKE" == *"fedora"* || "$DIST_LIKE" == *"rhel"* ]]; then
        install_fedora_like
      else
        gum style --foreground 196 "Unsupported distribution: $DIST_ID"; exit 2
      fi
      ;;
  esac

  enable_start_service
  configure_docker_group
  print_versions
  gum style --faint "Note: No firewall or application configuration was changed."
  
  # Run health check
  run_docker_health_check
}

run_docker_health_check() {
  if ! declare -f health_check_summary >/dev/null 2>&1; then
    log_warn "Health check functions not available, skipping validation"
    return 0
  fi
  
  local checks=(
    "validate_command docker '[0-9]+\\.[0-9]+'"
    "validate_service_enabled docker"
    "validate_service_running docker"
  )
  
  # Check Docker Compose plugin
  if docker compose version >/dev/null 2>&1; then
    checks+=("docker compose version >/dev/null 2>&1")
  fi
  
  # Check if docker daemon is responding
  checks+=("docker info >/dev/null 2>&1")
  
  # Check if user can run docker without sudo (will fail for root, but that's expected)
  if [[ $EUID -ne 0 ]]; then
    checks+=("groups | grep -q docker || echo 'User not in docker group (run: sudo usermod -aG docker \$USER)'")
  fi
  
  health_check_summary "Docker" "${checks[@]}"
}

main "$@"
