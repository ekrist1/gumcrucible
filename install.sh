#!/usr/bin/env bash
# Crucible initial installer
# Installs charmbracelet/gum on Ubuntu or Fedora, then launches startup menu.
set -euo pipefail

# --- new: repo + logging options ---
REPO_URL="https://github.com/ekrist1/gumcrucible.git"
DEFAULT_BRANCH="main"
BRANCH="$DEFAULT_BRANCH"
TARGET_DIR="${HOME}/gumcrucible"
LOG_FILE="${TMPDIR:-/tmp}/gumcrucible-install.log"

# consume known args; pass the rest through to startup.sh
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir) TARGET_DIR="${2:-}"; shift 2 ;;
    -b|--branch) BRANCH="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: $(basename "$0") [-d DIR] [-b BRANCH] [-- ARGS_FOR_STARTUP]"
      exit 0
      ;;
    --) shift; break ;;
    *) break ;;
  esac
done
# append all stderr to a log file
exec 2>>"$LOG_FILE"
trap 'echo "[crucible][error] Failed on line $LINENO. See $LOG_FILE" >&2' ERR
# --- end new ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command_exists() { command -v "$1" >/dev/null 2>&1; }

echo "[crucible] Starting install script"

# --- changed: don't exit early if gum exists; continue to repo setup ---
if command_exists gum; then
  echo "[crucible] gum already installed ($(gum --version)). Proceeding to repository setup..."
fi
# --- end changed ---

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

# --- changed: only prompt/install gum when missing ---
if ! command_exists gum; then
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
fi
# --- end changed ---

# --- new: repo acquisition helpers ---
ensure_git() {
  if command_exists git; then return 0; fi
  echo "[crucible] git not found. Attempting to install..."
  if command_exists apt-get; then
    run apt-get update -y || true
    run apt-get install -y git curl ca-certificates
  elif command_exists dnf; then
    run dnf install -y git curl ca-certificates
  else
    echo "[crucible][error] No supported package manager found to install git." >&2
    return 1
  fi
}

download_repo() {
  mkdir -p "$TARGET_DIR"
  if ensure_git 2>/dev/null; then
    if [[ -d "$TARGET_DIR/.git" ]]; then
      echo "[crucible] Existing repository detected at $TARGET_DIR. Updating..."
      git -C "$TARGET_DIR" fetch --all --prune
      git -C "$TARGET_DIR" checkout "$BRANCH"
      git -C "$TARGET_DIR" pull --ff-only origin "$BRANCH"
    else
      echo "[crucible] Cloning $REPO_URL (branch: $BRANCH) into $TARGET_DIR"
      git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TARGET_DIR"
    fi
  else
    echo "[crucible] Falling back to tarball download..."
    local url="https://github.com/ekrist1/gumcrucible/archive/refs/heads/${BRANCH}.tar.gz"
    curl -fsSL "$url" | tar -xz -C "$TARGET_DIR" --strip-components=1
  fi
}

make_executable() {
  echo "[crucible] Marking shell scripts executable in $TARGET_DIR"
  find "$TARGET_DIR" -type f -name "*.sh" -exec chmod +x {} +
}
# --- end new ---

# --- changed: resolve startup.sh location, fetching repo when needed ---
STARTUP=""
INSTALL_BASE=""
if [[ -f "${SCRIPT_DIR}/startup.sh" ]]; then
  STARTUP="${SCRIPT_DIR}/startup.sh"
  INSTALL_BASE="${SCRIPT_DIR}"
else
  echo "[crucible] Local startup.sh not found next to installer. Fetching repository..."
  download_repo
  make_executable
  STARTUP="${TARGET_DIR}/startup.sh"
  INSTALL_BASE="${TARGET_DIR}"
fi

# Source progress library now that we know where the install scripts are
PROGRESS_LIB="${INSTALL_BASE}/install/lib/progress.sh"
if [[ -f "$PROGRESS_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$PROGRESS_LIB"
fi

echo "[crucible] Launching startup menu: $STARTUP"
exec "$STARTUP" "$@"
# --- end changed ---
