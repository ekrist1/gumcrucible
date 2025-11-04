#!/usr/bin/env bash
# Install mkcert (local development certificates) and trust the local CA
# Supports Ubuntu/Debian and Fedora/RHEL-like. Uses gum for UX and progress.
set -euo pipefail

export CRUCIBLE_COMPONENT="mcert"
MKCERT_VERSION="v1.4.4"

PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"

if ! command -v gum >/dev/null 2>&1; then
  echo "[mcert][warn] gum not found; proceeding without fancy UI" >&2
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
  gum style --foreground 196 "[mcert][error] Cannot detect OS"; exit 1
fi

already_installed() {
  command_exists mkcert
}

install_ubuntu_debian() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Install dependencies
  local base=(curl ca-certificates libnss3-tools)
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing prerequisites" "${base[@]}"
  else
    gum spin --spinner line --title "Installing prerequisites" -- bash -c "${sudo_cmd:-} apt-get update >/dev/null 2>&1 && ${sudo_cmd:-} apt-get install -y ${base[*]} >/dev/null 2>&1"
  fi

  # Try official apt package first (on newer Ubuntu)
  if apt-cache policy mkcert 2>/dev/null | grep -q "Candidate"; then
    if declare -f pb_packages >/dev/null 2>&1; then
      pb_packages "Installing mkcert" mkcert
    else
      gum spin --spinner line --title "Installing mkcert" -- bash -c "${sudo_cmd:-} apt-get install -y mkcert >/dev/null 2>&1"
    fi
  else
    # Fallback: download release binary
    local url
    local arch
    arch=$(uname -m)
    case "$arch" in
      x86_64|amd64) url="https://github.com/FiloSottile/mkcert/releases/download/${MKCERT_VERSION}/mkcert-${MKCERT_VERSION}-linux-amd64" ;;
      aarch64|arm64) url="https://github.com/FiloSottile/mkcert/releases/download/${MKCERT_VERSION}/mkcert-${MKCERT_VERSION}-linux-arm64" ;;
      *) gum style --foreground 196 "Unsupported arch: $arch"; exit 2 ;;
    esac
    gum spin --spinner line --title "Downloading mkcert" -- bash -c "curl -fsSL '$url' -o /tmp/mkcert && chmod +x /tmp/mkcert"
    gum spin --spinner line --title "Installing mkcert to /usr/local/bin" -- bash -c "${sudo_cmd:-} mv /tmp/mkcert /usr/local/bin/mkcert"
  fi
}

install_fedora_like() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing mkcert and trust tools" mkcert nss-tools
  else
    gum spin --spinner line --title "Installing mkcert and trust tools" -- bash -c "${sudo_cmd:-} dnf install -y mkcert nss-tools >/dev/null 2>&1 || true"
  fi

  if ! command_exists mkcert; then
    # Fallback to binary download
    local url
    local arch
    arch=$(uname -m)
    case "$arch" in
      x86_64|amd64) url="https://github.com/FiloSottile/mkcert/releases/download/${MKCERT_VERSION}/mkcert-${MKCERT_VERSION}-linux-amd64" ;;
      aarch64|arm64) url="https://github.com/FiloSottile/mkcert/releases/download/${MKCERT_VERSION}/mkcert-${MKCERT_VERSION}-linux-arm64" ;;
      *) gum style --foreground 196 "Unsupported arch: $arch"; exit 2 ;;
    esac
    gum spin --spinner line --title "Downloading mkcert" -- bash -c "curl -fsSL '$url' -o /tmp/mkcert && chmod +x /tmp/mkcert"
    gum spin --spinner line --title "Installing mkcert to /usr/local/bin" -- bash -c "${sudo_cmd:-} mv /tmp/mkcert /usr/local/bin/mkcert"
  fi
}

trust_local_ca() {
  # mkcert will auto-select Linux trust stores and use nss tools if available
  if command -v mkcert >/dev/null 2>&1; then
    gum spin --spinner line --title "Creating and trusting local CA (mkcert -install)" -- bash -c "mkcert -install >/dev/null 2>&1 || true"
  fi
}

show_usage_examples() {
  gum style --foreground 212 --bold "mkcert installed"
  gum style --faint "Examples:"
  gum style --faint "  mkcert localhost 127.0.0.1 ::1"
  gum style --faint "  mkcert dev.myapp.test"
  gum style --faint "Certs are written in the current directory by default."
}

main() {
  if already_installed; then
    gum style --foreground 82 "mkcert already installed"
    trust_local_ca || true
    mkcert --version 2>/dev/null | head -n1 | xargs -I{} gum style --foreground 212 --bold {}
    exit 0
  fi

  case "$DIST_ID" in
    ubuntu|debian) install_ubuntu_debian ;;
    fedora) install_fedora_like ;;
    *)
      if [[ "$DIST_LIKE" == *"debian"* ]]; then
        install_ubuntu_debian
      elif [[ "$DIST_LIKE" == *"fedora"* || "$DIST_LIKE" == *"rhel"* || "$DIST_LIKE" == *"centos"* ]]; then
        install_fedora_like
      else
        gum style --foreground 196 "Unsupported distribution: $DIST_ID"; exit 3
      fi
      ;;
  esac

  if ! command_exists mkcert; then
    gum style --foreground 196 "mkcert installation appears to have failed"; exit 4
  fi

  trust_local_ca
  show_usage_examples
}

main "$@"
