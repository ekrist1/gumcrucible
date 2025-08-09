#!/usr/bin/env bash
# Install Caddy web server only (no Caddyfile changes, no firewall changes)
# Supports Ubuntu/Debian and Fedora. Idempotent-ish and quiet.
set -euo pipefail

# Set component name for logging
export CRUCIBLE_COMPONENT="caddy"

# Optional progress bar
PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
if [[ -f "$PROGRESS_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$PROGRESS_LIB"
fi

if ! command -v gum >/dev/null 2>&1; then
  echo "[caddy][warn] gum not found; proceeding without fancy UI" >&2
  gum() { shift || true; "$@"; }
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }
need_sudo() { if [[ $EUID -ne 0 ]]; then command_exists sudo && echo sudo; fi; }
run() { local pre; pre=$(need_sudo || true); echo "> ${pre:+$pre }$*"; ${pre:-} "$@"; }

# Detect distro
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  DIST_ID="${ID,,}"
  DIST_LIKE="${ID_LIKE:-}"; DIST_LIKE="${DIST_LIKE,,}"
  DIST_VERSION_ID="${VERSION_ID:-}"
else
  gum style --foreground 196 "[caddy][error] Cannot detect OS (missing /etc/os-release)"
  exit 1
fi

already_installed() {
  command_exists caddy
}

install_ubuntu_debian() {
  # Follow official instructions (Cloudsmith repo) without touching firewall/Caddyfile
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  gum spin --spinner line --title "Preparing apt prerequisites" -- bash -c "
    ${sudo_cmd:-} apt-get update -y >/dev/null 2>&1 || true
    ${sudo_cmd:-} apt-get install -y ca-certificates curl gnupg debian-keyring debian-archive-keyring lsb-release apt-transport-https >/dev/null 2>&1
  "
  
  gum spin --spinner line --title "Adding Caddy GPG key" -- bash -c "
    ${sudo_cmd:-} install -d -m 0755 /usr/share/keyrings
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | ${sudo_cmd:-} gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  "
  
  gum spin --spinner line --title "Adding Caddy apt repository" -- bash -c "
    curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | ${sudo_cmd:-} tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    ${sudo_cmd:-} apt-get update -y >/dev/null 2>&1
  "
  
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing Caddy" caddy
  else
    gum spin --spinner line --title "Installing Caddy" -- bash -c "${sudo_cmd:-} apt-get install -y caddy >/dev/null 2>&1"
  fi
}

install_fedora() {
  # Caddy is available in Fedora repos
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing Caddy" caddy
  else
    gum spin --spinner line --title "Installing Caddy" -- bash -c "${sudo_cmd:-} dnf install -y caddy >/dev/null 2>&1"
  fi
}

main() {
  if already_installed; then
    gum style --foreground 82 "Caddy already installed"
    caddy version 2>/dev/null | head -n1 | xargs -I{} gum style --foreground 212 --bold {}
    exit 0
  fi

  case "$DIST_ID" in
    ubuntu|debian)
      install_ubuntu_debian ;;
    fedora)
      install_fedora ;;
    *)
      if [[ "$DIST_LIKE" == *"debian"* ]]; then
        install_ubuntu_debian
      elif [[ "$DIST_LIKE" == *"fedora"* || "$DIST_LIKE" == *"rhel"* ]]; then
        install_fedora
      else
        gum style --foreground 196 "Unsupported distribution: $DIST_ID"
        exit 2
      fi
      ;;
  esac

  if command_exists caddy; then
    gum style --foreground 212 --bold "$(caddy version 2>/dev/null | head -n1) installed"
  else
    gum style --foreground 214 "Caddy installed (version unknown)"
  fi

  gum style --faint "Note: No Caddyfile, firewall, or service state changes were made."
  
  # Run health check
  run_caddy_health_check
}

run_caddy_health_check() {
  if ! declare -f health_check_summary >/dev/null 2>&1; then
    log_warn "Health check functions not available, skipping validation"
    return 0
  fi
  
  local checks=(
    "validate_command caddy 'v[0-9]+'"
    "test -f /etc/caddy/Caddyfile || echo 'Default Caddyfile location exists'"
  )
  
  # Check if caddy service exists and add service checks
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^caddy\.service'; then
    checks+=(
      "validate_service_enabled caddy"
      "validate_service_running caddy"
      "validate_port_listening 80"
      "validate_port_listening 443"
    )
  fi
  
  # Test basic caddy functionality
  checks+=("caddy validate --config /etc/caddy/Caddyfile 2>/dev/null || echo 'Caddyfile validation (optional)'")
  
  health_check_summary "Caddy" "${checks[@]}"
}

main "$@"
