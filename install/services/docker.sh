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
  
  # Remove old packages (ignore failures)
  gum spin --spinner line --title "Removing old docker packages (if any)" -- bash -c "${sudo_cmd:-} apt-get remove -y docker docker-engine docker.io containerd runc >/dev/null 2>&1 || true"

  # Prereqs
  gum spin --spinner line --title "Installing prerequisites" -- bash -c "${sudo_cmd:-} apt-get update -y >/dev/null 2>&1; ${sudo_cmd:-} apt-get install -y ca-certificates curl gnupg lsb-release >/dev/null 2>&1"

  # Keyring
  gum spin --spinner line --title "Setting up Docker apt keyring" -- bash -c "
    ${sudo_cmd:-} install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/${ID}/gpg > /tmp/docker.gpg
    ${sudo_cmd:-} gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg
    ${sudo_cmd:-} chmod a+r /etc/apt/keyrings/docker.gpg
    rm -f /tmp/docker.gpg
  "

  # Repo
  local arch
  arch=$(dpkg --print-architecture)
  local distro_path repo_file
  if [[ "$DIST_ID" == "ubuntu" ]]; then
    distro_path="ubuntu"
  else
    distro_path="debian"
  fi
  repo_file="/etc/apt/sources.list.d/docker.list"
  gum spin --spinner line --title "Adding Docker apt repository" -- bash -c "echo \"deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro_path} ${VERSION_CODENAME} stable\" | ${sudo_cmd:-} tee ${repo_file} >/dev/null; ${sudo_cmd:-} apt-get update -y >/dev/null 2>&1"

  # Install packages
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
  
  # Remove old packages (ignore failures)
  gum spin --spinner line --title "Removing old docker packages (if any)" -- bash -c "${sudo_cmd:-} dnf remove -y docker docker-engine docker.io containerd runc >/dev/null 2>&1 || true"

  # Repo
  gum spin --spinner line --title "Adding Docker CE repo" -- bash -c "${sudo_cmd:-} dnf -y install dnf-plugins-core >/dev/null 2>&1 && ${sudo_cmd:-} dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo >/dev/null 2>&1 || true"

  # Install packages
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
    gum spin --spinner line --title "Enabling docker service" -- bash -c "${sudo_cmd:-} systemctl enable docker >/dev/null 2>&1 || true"
    gum spin --spinner line --title "Starting docker service" -- bash -c "${sudo_cmd:-} systemctl restart docker >/dev/null 2>&1 || true"
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
