#!/usr/bin/env bash
# Install Docker Engine, CLI, Buildx and Compose v2 plugin
# Supports Ubuntu/Debian and Fedora. Enables and starts docker service.
# No firewall or app config changes.
set -euo pipefail

PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"

if ! command -v gum >/dev/null 2>&1; then
  echo "[docker][warn] gum not found; proceeding without fancy UI" >&2
  gum() { shift || true; "$@"; }
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }

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
  # Remove old packages (ignore failures)
  gum spin --spinner line --title "Removing old docker packages (if any)" -- bash -c 'apt-get remove -y docker docker-engine docker.io containerd runc >/dev/null 2>&1 || true'

  # Prereqs
  gum spin --spinner line --title "Installing prerequisites" -- bash -c 'apt-get update -y >/dev/null 2>&1; apt-get install -y ca-certificates curl gnupg lsb-release >/dev/null 2>&1'

  # Keyring
  gum spin --spinner line --title "Setting up Docker apt keyring" -- bash -c '
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/${ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  '

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
  gum spin --spinner line --title "Adding Docker apt repository" -- bash -c "echo \"deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro_path} ${VERSION_CODENAME} stable\" > ${repo_file}; apt-get update -y >/dev/null 2>&1"

  # Install packages
  local pkgs=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing Docker Engine & Compose" "${pkgs[@]}"
  else
    gum spin --spinner line --title "Installing Docker Engine & Compose" -- bash -c "apt-get install -y ${pkgs[*]} >/dev/null 2>&1"
  fi
}

install_fedora_like() {
  # Remove old packages (ignore failures)
  gum spin --spinner line --title "Removing old docker packages (if any)" -- bash -c 'dnf remove -y docker docker-engine docker.io containerd runc >/dev/null 2>&1 || true'

  # Repo
  gum spin --spinner line --title "Adding Docker CE repo" -- bash -c 'dnf -y install dnf-plugins-core >/dev/null 2>&1 && dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo >/dev/null 2>&1 || true'

  # Install packages
  local pkgs=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing Docker Engine & Compose" "${pkgs[@]}"
  else
    gum spin --spinner line --title "Installing Docker Engine & Compose" -- bash -c "dnf install -y ${pkgs[*]} >/dev/null 2>&1"
  fi
}

enable_start_service() {
  if command_exists systemctl && systemctl list-unit-files | grep -q '^docker\.service'; then
    gum spin --spinner line --title "Enabling docker service" -- bash -c 'systemctl enable docker >/dev/null 2>&1 || true'
    gum spin --spinner line --title "Starting docker service" -- bash -c 'systemctl restart docker >/dev/null 2>&1 || true'
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
}

main "$@"
