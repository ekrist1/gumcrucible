#!/usr/bin/env bash
# Crucible initial installer
# Installs charmbracelet/gum on Ubuntu or Fedora, then launches startup menu.
set -euo pipefail

# Repository and configuration
REPO_URL="https://github.com/ekrist1/gumcrucible.git"
DEFAULT_BRANCH="main"
BRANCH="$DEFAULT_BRANCH"
TARGET_DIR="${HOME}/gumcrucible"
LOG_FILE="${TMPDIR:-/tmp}/gumcrucible-install.log"

# Parse command line arguments
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

# Initialize log file and error handling (but don't redirect stderr globally)
echo "=== Crucible Install Log - $(date) ===" > "$LOG_FILE"
log_error() {
  echo "[crucible][error] $*" | tee -a "$LOG_FILE" >&2
}
log_info() {
  echo "[crucible] $*" | tee -a "$LOG_FILE"
}
trap 'log_error "Failed on line $LINENO"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command_exists() { command -v "$1" >/dev/null 2>&1; }

# new: global sudo/runner helpers (needed even if gum is already installed)
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

log_info "Starting install script"
log_info "Logging to $LOG_FILE"

# --- changed: don't exit early if gum exists; continue to repo setup ---
if command_exists gum; then
  echo "[crucible] gum already installed ($(gum --version)). Proceeding to repository setup..."
fi
# --- end changed ---

# Require explicit consent before installing gum
confirm_install() {
  local prompt="This will add the Charm repository and install 'gum' on your system. Proceed? [y/N] "
  local reply
  
  # Show prompt directly to terminal (not stderr since it's not an error)
  echo -n "$prompt"
  
  # Try multiple methods to read from terminal
  if [[ -t 0 ]]; then
    # Standard input is connected to terminal
    read -r reply
  elif [[ -r /dev/tty ]]; then
    # Fallback to direct TTY access
    read -r reply < /dev/tty
  else
    # Non-interactive session
    echo ""
    log_error "Non-interactive session detected; refusing to install gum without confirmation."
    return 1
  fi
  
  case "${reply}" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

# --- changed: only prompt/install gum when missing ---
if ! command_exists gum; then
  if ! confirm_install; then
    log_info "Installation cancelled by user. Exiting."
    exit 0
  fi

  if [[ ! -r /etc/os-release ]]; then
    log_error "Cannot detect OS (missing /etc/os-release)"
    exit 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  ID_LIKE_LOWER="${ID_LIKE:-}"; ID_LIKE_LOWER="${ID_LIKE_LOWER,,}"
  ID_LOWER="${ID,,}"

  install_gum_ubuntu() {
    log_info "Installing gum for Ubuntu/Debian..."
    # changed: avoid '-y' with 'apt-get update'
    run apt-get update
    local base_packages=(curl ca-certificates gnupg lsb-release)
    if declare -f pb_packages >/dev/null 2>&1; then
      pb_packages "Installing prerequisites" "${base_packages[@]}"
    else
      run apt-get install -y "${base_packages[@]}"
    fi
    echo "deb [trusted=yes] https://repo.charm.sh/apt/ * *" | $(need_sudo tee /etc/apt/sources.list.d/charm.list) >/dev/null
    # changed: avoid '-y' with 'apt-get update'
    run apt-get update
    if declare -f pb_packages >/dev/null 2>&1; then
      pb_packages "Installing gum" gum
    else
      run apt-get install -y gum
    fi
  }

  install_gum_fedora() {
    log_info "Installing gum for Fedora..."
    local repo_file=/etc/yum.repos.d/charm.repo
    if [[ ! -f $repo_file ]]; then
      log_info "Adding charm repo at $repo_file"
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
      log_info "Charm repo already present"
    fi
    run dnf -y makecache || true
    if declare -f pb_packages >/dev/null 2>&1; then
      pb_packages "Installing gum" gum || true
    else
      run dnf install -y gum || {
        log_error "direct install failed, attempting plugin path"
        run dnf install -y dnf-plugins-core || true
        # changed: use 'run' for config-manager so sudo is applied
        if run dnf config-manager --help >/dev/null 2>&1; then
          run dnf config-manager --add-repo https://repo.charm.sh/yum/ 2>/dev/null || \
          run dnf config-manager addrepo https://repo.charm.sh/yum/ charm || true
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
        log_error "Unsupported distribution: ${ID}"
        exit 2
      fi
      ;;
  esac

  if ! command_exists gum; then
    log_error "gum installation appears to have failed"
    exit 3
  fi

  log_info "gum installed successfully ($(gum --version))"
fi
# --- end changed ---

# --- new: repo acquisition helpers ---
ensure_git() {
  if command_exists git; then return 0; fi
  log_info "git not found. Attempting to install..."
  if command_exists apt-get; then
    # changed: avoid '-y' with 'apt-get update'
    run apt-get update || true
    run apt-get install -y git curl ca-certificates
  elif command_exists dnf; then
    run dnf install -y git curl ca-certificates
  else
    log_error "No supported package manager found to install git."
    return 1
  fi
}

download_repo() {
  mkdir -p "$TARGET_DIR"
  if ensure_git 2>/dev/null; then
    if [[ -d "$TARGET_DIR/.git" ]]; then
      log_info "Existing repository detected at $TARGET_DIR. Updating..."
      git -C "$TARGET_DIR" fetch --all --prune 2>>"$LOG_FILE"
      git -C "$TARGET_DIR" checkout "$BRANCH" 2>>"$LOG_FILE"
      git -C "$TARGET_DIR" pull --ff-only origin "$BRANCH" 2>>"$LOG_FILE"
    else
      log_info "Cloning $REPO_URL (branch: $BRANCH) into $TARGET_DIR"
      git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TARGET_DIR" 2>>"$LOG_FILE"
    fi
  else
    log_info "Falling back to tarball download..."
    local url="https://github.com/ekrist1/gumcrucible/archive/refs/heads/${BRANCH}.tar.gz"
    curl -fsSL "$url" | tar -xz -C "$TARGET_DIR" --strip-components=1 2>>"$LOG_FILE"
  fi
}

make_executable() {
  log_info "Marking shell scripts executable in $TARGET_DIR"
  find "$TARGET_DIR" -type f -name "*.sh" -exec chmod +x {} + 2>>"$LOG_FILE"
}
# --- end new ---

# --- changed: resolve startup.sh location, fetching repo when needed ---
STARTUP=""
INSTALL_BASE=""
if [[ -f "${SCRIPT_DIR}/startup.sh" ]]; then
  STARTUP="${SCRIPT_DIR}/startup.sh"
  INSTALL_BASE="${SCRIPT_DIR}"
else
  log_info "Local startup.sh not found next to installer. Fetching repository..."
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

log_info "Launching startup menu: $STARTUP"

# Verify startup script exists and is executable
if [[ ! -f "$STARTUP" ]]; then
  log_error "Startup script not found: $STARTUP"
  exit 4
fi

if [[ ! -x "$STARTUP" ]]; then
  log_info "Making startup script executable: $STARTUP"
  chmod +x "$STARTUP"
fi

# Verify the repository was downloaded correctly
if [[ ! -d "$INSTALL_BASE/install" ]]; then
  log_error "Repository structure incomplete - missing install directory"
  log_error "Expected: $INSTALL_BASE/install"
  exit 5
fi

# Change to the repository directory before executing startup.sh
log_info "Changing to directory: $INSTALL_BASE"
cd "$INSTALL_BASE" || {
  log_error "Cannot change to directory: $INSTALL_BASE"
  exit 6
}

log_info "Current directory: $(pwd)"
log_info "Repository contents:"
ls -la | head -10 2>>"$LOG_FILE"

log_info "Executing startup script: ./startup.sh"
exec ./startup.sh "$@"
# --- end changed ---
