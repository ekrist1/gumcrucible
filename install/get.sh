#!/usr/bin/env bash
# Fetch gumcrucible repo and ensure scripts are executable
set -euo pipefail

REPO_URL="https://github.com/ekrist1/gumcrucible.git"
DEFAULT_BRANCH="main"
TARGET_DIR="${HOME}/gumcrucible"
BRANCH="$DEFAULT_BRANCH"
LOG_FILE="${TMPDIR:-/tmp}/gumcrucible-bootstrap.log"

command_exists() { command -v "$1" >/dev/null 2>&1; }

style() {
  local msg="$1" fg="${2:-white}" label="${3:-}"
  if command_exists gum; then
    if [[ -n "$label" ]]; then
      gum style --foreground "$fg" --border normal --border-foreground "$fg" "[$label] $msg"
    else
      gum style --foreground "$fg" "$msg"
    fi
  else
    echo "$msg"
  fi
}

err() { style "$*" red "error" >&2; }

usage() {
  cat <<USAGE
Usage: $(basename "$0") [-d DIR] [-b BRANCH]
  -d, --dir DIR     Target directory (default: \$HOME/gumcrucible)
  -b, --branch BR   Branch or tag to fetch (default: ${DEFAULT_BRANCH})
  -h, --help        Show help
USAGE
}

trap 'err "Error on line $LINENO. See $LOG_FILE"; exit 1' ERR
# Append script stderr to log file
exec 2>>"$LOG_FILE"

need_sudo() {
  if [[ $EUID -ne 0 ]]; then
    if command_exists sudo; then echo sudo "$@"; else echo "$@"; fi
  else
    echo "$@"
  fi
}

run() { local cmd; cmd=$(need_sudo "$@"); echo "> $cmd"; eval "$cmd"; }

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir) TARGET_DIR="${2:-}"; shift 2 ;;
    -b|--branch) BRANCH="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

style "Preparing to fetch gumcrucible into: $TARGET_DIR (branch: $BRANCH)" cyan "info"
mkdir -p "$TARGET_DIR"

ensure_git() {
  if command_exists git; then return 0; fi
  style "git not found. Attempting to install..." yellow "info"
  if [[ -r /etc/os-release ]]; then . /etc/os-release || true; fi
  if command_exists apt-get; then
    run apt-get update -y >/dev/null 2>&1 || true
    run apt-get install -y git >/dev/null 2>&1
  elif command_exists dnf; then
    run dnf install -y git >/dev/null 2>&1
  else
    err "No supported package manager found. Please install git manually."
    return 1
  fi
}

download_repo() {
  if ensure_git; then
    if [[ -d "$TARGET_DIR/.git" ]]; then
      style "Existing repo detected. Updating..." cyan "info"
      git -C "$TARGET_DIR" fetch --all --prune
      git -C "$TARGET_DIR" checkout "$BRANCH"
      git -C "$TARGET_DIR" pull --ff-only origin "$BRANCH"
    else
      style "Cloning $REPO_URL ..." cyan "info"
      git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TARGET_DIR"
    fi
  else
    style "Falling back to tarball download..." yellow "info"
    local url="https://github.com/ekrist1/gumcrucible/archive/refs/heads/${BRANCH}.tar.gz"
    curl -fsSL "$url" | tar -xz -C "$TARGET_DIR" --strip-components=1
  fi
}

make_executable() {
  style "Marking shell scripts executable..." cyan "info"
  # Make *.sh executable
  find "$TARGET_DIR" -type f -name "*.sh" -exec chmod +x {} +
  # Additionally, make any shebang-based scripts in install/ and operation/ executable
  find "$TARGET_DIR" -type f \( -path "*/install/*" -o -path "*/operation/*" \) \
    -exec sh -c 'for f in "$@"; do head -n1 "$f" | grep -qE "^#\!.*(bash|sh)" && chmod +x "$f"; done' sh {} +
}

download_repo
make_executable

style "Done." green "ok"
echo "Next:"
echo "  cd \"$TARGET_DIR\""
echo "  ./install.sh"
