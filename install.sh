#!/usr/bin/env bash
# Crucible initial installer
# Installs charmbracelet/gum on Ubuntu or Fedora, then launches startup menu.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROGRESS_LIB="${SCRIPT_DIR}/install/lib/progress.sh"
if [[ -f "$PROGRESS_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$PROGRESS_LIB"
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }

echo "[crucible] Starting install script"

if command_exists gum; then
  echo "[crucible] gum already installed ($(gum --version)). Launching startup menu..."
  exec "${SCRIPT_DIR}/startup.sh" "$@"
fi

# Require explicit consent before installing gum
confirm_install() {
  local prompt="This will add the Charm repository and install 'gum' on your system. Proceed? [y/N] "
  local reply
  # Read from TTY when available to avoid piping issues
  if [[ -t 0 ]]; then
    read -r -p "$prompt" reply
  else
    # Attempt reading from /dev/tty; if not available, abort
    if [[ -r /dev/tty ]]; then
      exec < /dev/tty
      read -r -p "$prompt" reply
    else
      echo "[crucible] Non-interactive session detected; refusing to install gum without confirmation." >&2
      return 1
    fi
  fi
  case "${reply}" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

if ! confirm_install; then
  echo "[crucible] Installation cancelled by user. Exiting."
  exit 0
fi

if [[ ! -r /etc/os-release ]]; then
  echo "[crucible][error] Cannot detect OS (missing /etc/os-release)" >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
ID_LIKE_LOWER="${ID_LIKE:-}"; ID_LIKE_LOWER="${ID_LIKE_LOWER,,}"
ID_LOWER="${ID,,}"

need_sudo() {
  if [[ $EUID -ne 0 ]]; then
    if command_exists sudo; then
      echo sudo "$@"
    else
      echo "$@"
    fi
  else
    echo "$@"
  fi
}

run() {
  local cmd
  cmd=$(need_sudo "$@")
  echo "> $cmd"
  eval "$cmd"
}

install_gum_ubuntu() {
  echo "[crucible] Installing gum for Ubuntu/Debian..."
  run apt-get update -y
  local base_packages=(curl ca-certificates gnupg lsb-release)
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing prerequisites" "${base_packages[@]}"
  else
    run apt-get install -y "${base_packages[@]}"
  fi
  echo "deb [trusted=yes] https://repo.charm.sh/apt/ * *" | $(need_sudo tee /etc/apt/sources.list.d/charm.list) >/dev/null
  run apt-get update -y
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing gum" gum
  else
    run apt-get install -y gum
  fi
}

install_gum_fedora() {
  echo "[crucible] Installing gum for Fedora..."
  local repo_file=/etc/yum.repos.d/charm.repo
  if [[ ! -f $repo_file ]]; then
    echo "[crucible] Adding charm repo at $repo_file"
    if [[ $EUID -ne 0 && $(command -v sudo) ]]; then
      sudo tee "$repo_file" >/dev/null <<'EOF'
[charm]
name=Charm Repo
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=0
EOF
    else
      cat > "$repo_file" <<'EOF'
[charm]
name=Charm Repo
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=0
EOF
    fi
  else
    echo "[crucible] Charm repo already present"
  fi
  run dnf -y makecache || true
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing gum" gum || true
  else
    run dnf install -y gum || {
      echo "[crucible][warn] direct install failed, attempting plugin path" >&2
      run dnf install -y dnf-plugins-core || true
      if dnf config-manager --help >/dev/null 2>&1; then
        dnf config-manager --add-repo https://repo.charm.sh/yum/ 2>/dev/null || \
        dnf config-manager addrepo https://repo.charm.sh/yum/ charm || true
        run dnf install -y gum
      fi
    }
  fi
}

case "${ID_LOWER}" in
  ubuntu|debian)
    install_gum_ubuntu
    ;;
  fedora)
    install_gum_fedora
    ;;
  *)
    if [[ "${ID_LIKE_LOWER}" == *"debian"* ]]; then
      install_gum_ubuntu
    elif [[ "${ID_LIKE_LOWER}" == *"fedora"* || "${ID_LIKE_LOWER}" == *"rhel"* || "${ID_LIKE_LOWER}" == *"centos"* ]]; then
      install_gum_fedora
    else
      echo "[crucible][error] Unsupported distribution: ${ID}" >&2
      exit 2
    fi
    ;;
esac

if ! command_exists gum; then
  echo "[crucible][error] gum installation appears to have failed" >&2
  exit 3
fi

echo "[crucible] gum installed successfully ($(gum --version))"
exec "${SCRIPT_DIR}/startup.sh" "$@"
