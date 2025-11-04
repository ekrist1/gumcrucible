#!/usr/bin/env bash
# Install MySQL Server (or MariaDB if preferred/available) with client tools
# Supports Ubuntu/Debian and Fedora/RHEL-like. Enables and starts mysql service.
# No firewall or app config changes.
set -euo pipefail

export CRUCIBLE_COMPONENT="mysql"
SECURE_TOOL_RAN=0

PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"

if ! command -v gum >/dev/null 2>&1; then
  echo "[mysql][warn] gum not found; proceeding without fancy UI" >&2
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
  gum style --foreground 196 "[mysql][error] Cannot detect OS"; exit 1
fi

already_installed() {
  # consider installed if a server binary or service exists
  if command_exists mysqld || command_exists mariadbd; then return 0; fi
  if command_exists systemctl && systemctl list-unit-files 2>/dev/null | grep -qE '^(mysql|mysqld|mariadb)\\.service'; then return 0; fi
  return 1
}

install_ubuntu_debian() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Prefer MySQL community server on Ubuntu; fall back to MariaDB if needed
  # Update package index first
  gum spin --spinner line --title "Updating package index" -- bash -c "${sudo_cmd:-} apt-get update >/dev/null 2>&1"

  # Try installing mysql-server; if unavailable, install mariadb-server instead
  if apt-cache policy mysql-server | grep -q Candidate; then
    local pkgs=(mysql-server mysql-client)
    if declare -f pb_packages >/dev/null 2>&1; then
      pb_packages "Installing MySQL Server" "${pkgs[@]}"
    else
      gum spin --spinner line --title "Installing MySQL Server" -- bash -c "${sudo_cmd:-} apt-get install -y ${pkgs[*]} >/dev/null 2>&1"
    fi
  else
    local pkgs=(mariadb-server mariadb-client)
    if declare -f pb_packages >/dev/null 2>&1; then
      pb_packages "Installing MariaDB Server" "${pkgs[@]}"
    else
      gum spin --spinner line --title "Installing MariaDB Server" -- bash -c "${sudo_cmd:-} apt-get install -y ${pkgs[*]} >/dev/null 2>&1"
    fi
  fi
}

install_fedora_like() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Try MySQL from the official module; if not available, use MariaDB (default in Fedora)
  gum spin --spinner line --title "Refreshing package metadata" -- bash -c "${sudo_cmd:-} dnf makecache >/dev/null 2>&1"

  # Prefer community-mysql if available
  if dnf list --available 2>/dev/null | grep -q '^community-mysql-server'; then
    local pkgs=(community-mysql-server community-mysql)
    if declare -f pb_packages >/dev/null 2>&1; then
      pb_packages "Installing MySQL Server" "${pkgs[@]}"
    else
      gum spin --spinner line --title "Installing MySQL Server" -- bash -c "${sudo_cmd:-} dnf install -y ${pkgs[*]} >/dev/null 2>&1"
    fi
  else
    local pkgs=(mariadb-server mariadb)
    if declare -f pb_packages >/dev/null 2>&1; then
      pb_packages "Installing MariaDB Server" "${pkgs[@]}"
    else
      gum spin --spinner line --title "Installing MariaDB Server" -- bash -c "${sudo_cmd:-} dnf install -y ${pkgs[*]} >/dev/null 2>&1"
    fi
  fi
}

enable_start_service() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  if command_exists systemctl; then
    # Enable and start one of the services if present
    for svc in mysqld mysql mariadb; do
      if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\\.service"; then
        gum spin --spinner line --title "Enabling and starting ${svc}" -- bash -c "${sudo_cmd:-} systemctl enable --now ${svc} >/dev/null 2>&1 || true"
        return 0
      fi
    done
  fi
}

secure_installation_note() {
  # Show guidance only if the interactive step was skipped or tool unavailable
  if [[ "${SECURE_TOOL_RAN:-0}" -eq 0 ]]; then
    gum style --foreground 214 --bold "Security: run mysql_secure_installation to harden your server."
    gum style --faint "Example: sudo mysql_secure_installation"
  fi
}

prompt_secure_installation() {
  local tool=""
  if command_exists mysql_secure_installation; then
    tool="mysql_secure_installation"
  elif command_exists mariadb-secure-installation; then
    tool="mariadb-secure-installation"
  fi

  if [[ -z "$tool" ]]; then
    gum style --foreground 196 "Secure installation tool not found; skipping hardening step"
    return 0
  fi

  gum style --foreground 45 --bold "MySQL secure installation"
  gum style --faint "This will help you set a root password, remove test DB, and disable remote root login."
  if gum confirm "Run $tool now?"; then
    echo
    local sudo_cmd
    sudo_cmd=$(need_sudo || true)
    # Run interactively; do not wrap with spinner
    ${sudo_cmd:-} "$tool" || true
    SECURE_TOOL_RAN=1
  fi
}

print_versions() {
  if command_exists mysql; then
    mysql --version 2>/dev/null | head -n1 | xargs -I{} gum style --foreground 212 --bold {}
  elif command_exists mariadb; then
    mariadb --version 2>/dev/null | head -n1 | xargs -I{} gum style --foreground 212 --bold {}
  fi
}

run_mysql_health_check() {
  if ! declare -f health_check_summary >/dev/null 2>&1; then
    # Quietly skip if not available in this context
    return 0
  fi
  local checks=()
  local svc=""
  if command_exists systemctl; then
    for s in mysql mysqld mariadb; do
      if systemctl list-unit-files 2>/dev/null | grep -q "^${s}\\.service"; then svc="$s"; break; fi
    done
  fi
  if [[ -n "$svc" ]]; then
    checks+=("validate_service_enabled $svc")
    checks+=("validate_service_running $svc")
  fi
  # Can we connect locally with socket without password (fresh installs often allow root@local_socket)
  checks+=("echo 'SELECT 1;' | mysql --protocol=socket -N 2>/dev/null >/dev/null || true")
  health_check_summary "MySQL/MariaDB" "${checks[@]}"
}

main() {
  if already_installed; then
    gum style --foreground 82 "MySQL (or MariaDB) detected"
    enable_start_service || true
    print_versions || true
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
  prompt_secure_installation
  secure_installation_note
  gum style --faint "Note: No firewall or application configuration was changed."

  run_mysql_health_check
}

main "$@"
