#!/usr/bin/env bash
# Install Node.js and npm (using NodeSource), with optional PM2
# Supports Ubuntu/Debian and Fedora/RHEL-like. Integrates with gum and progress.
set -euo pipefail

export CRUCIBLE_COMPONENT="node"

PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"

if ! command -v gum >/dev/null 2>&1; then
  echo "[node][warn] gum not found; proceeding without fancy UI" >&2
  gum() { shift || true; "$@"; }
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }
need_sudo() { if [[ $EUID -ne 0 ]]; then command_exists sudo && echo sudo; fi; }

# Detect OS
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  DIST_ID="${ID,,}"
  DIST_LIKE="${ID_LIKE:-}"; DIST_LIKE="${DIST_LIKE,,}"
else
  gum style --foreground 196 "[node][error] Cannot detect OS"; exit 1
fi

already_installed() {
  command_exists node && command_exists npm
}

print_versions() {
  node --version 2>/dev/null | xargs -I{} gum style --foreground 212 --bold "node {}" || true
  npm --version 2>/dev/null | xargs -I{} gum style --foreground 212 --bold "npm {}" || true
}

install_nodesource_debian() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Prereqs
  local base=(curl ca-certificates)
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing prerequisites" "${base[@]}"
  else
    gum spin --spinner line --title "Installing prerequisites" -- bash -c "${sudo_cmd:-} apt-get update >/dev/null 2>&1 && ${sudo_cmd:-} apt-get install -y ${base[*]} >/dev/null 2>&1"
  fi

  # Setup NodeSource (LTS)
  gum spin --spinner line --title "Configuring NodeSource (LTS)" -- bash -c "curl -fsSL https://deb.nodesource.com/setup_lts.x | ${sudo_cmd:-} bash - >/dev/null 2>&1"

  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing Node.js (LTS)" nodejs
  else
    gum spin --spinner line --title "Installing Node.js (LTS)" -- bash -c "${sudo_cmd:-} apt-get install -y nodejs >/dev/null 2>&1"
  fi
}

install_nodesource_fedora() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing prerequisites" curl ca-certificates
  else
    gum spin --spinner line --title "Installing prerequisites" -- bash -c "${sudo_cmd:-} dnf install -y curl ca-certificates >/dev/null 2>&1"
  fi

  gum spin --spinner line --title "Configuring NodeSource (LTS)" -- bash -c "curl -fsSL https://rpm.nodesource.com/setup_lts.x | ${sudo_cmd:-} bash - >/dev/null 2>&1"

  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing Node.js (LTS)" nodejs
  else
    gum spin --spinner line --title "Installing Node.js (LTS)" -- bash -c "${sudo_cmd:-} dnf install -y nodejs >/dev/null 2>&1"
  fi
}

maybe_install_pm2() {
  if gum confirm "Install PM2 (process manager) globally?"; then
    local sudo_cmd
    sudo_cmd=$(need_sudo || true)
    gum spin --spinner line --title "Installing PM2" -- bash -c "${sudo_cmd:-} npm install -g pm2 >/dev/null 2>&1"
    gum style --foreground 82 "PM2 installed"
    gum style --faint "Try: pm2 startup && pm2 save"
  fi
}

main() {
  if already_installed; then
    gum style --foreground 82 "Node & npm already installed"
    print_versions || true
    maybe_install_pm2 || true
    exit 0
  fi

  case "$DIST_ID" in
    ubuntu|debian) install_nodesource_debian ;;
    fedora) install_nodesource_fedora ;;
    *)
      if [[ "$DIST_LIKE" == *"debian"* ]]; then
        install_nodesource_debian
      elif [[ "$DIST_LIKE" == *"fedora"* || "$DIST_LIKE" == *"rhel"* || "$DIST_LIKE" == *"centos"* ]]; then
        install_nodesource_fedora
      else
        gum style --foreground 196 "Unsupported distribution: $DIST_ID"; exit 2
      fi
      ;;
  esac

  if ! already_installed; then
    gum style --foreground 196 "Node.js installation appears to have failed"; exit 3
  fi

  print_versions
  maybe_install_pm2
}

main "$@"
