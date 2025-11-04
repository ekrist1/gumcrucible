#!/usr/bin/env bash
# Install PHP Composer (dependency manager) without altering firewall or other configs.
# Prefers official installer when PHP CLI is available; otherwise, instructs to install PHP first.
set -euo pipefail

# Set component name for logging
export CRUCIBLE_COMPONENT="composer"

PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"

if ! command -v gum >/dev/null 2>&1; then
  echo "[composer][warn] gum not found; proceeding without fancy UI" >&2
  # Fallback: emulate minimal gum behavior
  gum() {
    case "$1" in
      style)
        shift
        echo "$*"
        ;;
      spin)
        shift
        # Execute the command after the '--'
        while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
        shift || true
        "$@"
        ;;
      *)
        shift || true
        "$@"
        ;;
    esac
  }
fi

# Add a safe warn logger if not provided by the environment
if ! declare -f log_warn >/dev/null 2>&1; then
  log_warn() {
    gum style --foreground 214 "[composer][warn] $*"
  }
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }
need_sudo() { if [[ $EUID -ne 0 ]]; then command_exists sudo && echo sudo; fi; }

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  DIST_ID="${ID,,}"; DIST_LIKE="${ID_LIKE:-}"; DIST_LIKE="${DIST_LIKE,,}"
else
  gum style --foreground 196 "[composer][error] Cannot detect OS"; exit 1
fi

already_installed() { command_exists composer; }

install_via_official() {
  # Requires PHP CLI; installs to /usr/local/bin/composer
  # Uses official programmatic installation method from getcomposer.org/doc/faqs/how-to-install-composer-programmatically.md
  if ! command_exists php; then
    gum style --foreground 196 --bold "PHP CLI is required for Composer installer."
    gum style --faint "Tip: Use Core Services -> Install PHP 8.4 first."
    return 2
  fi
  
  local tmpdir
  tmpdir=$(mktemp -d)
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  gum spin --spinner line --title "Installing Composer via official installer" -- bash -c "
    cd '$tmpdir' || exit 1
    
    # Official programmatic installation script
    EXPECTED_CHECKSUM=\"\$(php -r 'copy(\"https://composer.github.io/installer.sig\", \"php://stdout\");')\"
    php -r 'copy(\"https://getcomposer.org/installer\", \"composer-setup.php\");'
    ACTUAL_CHECKSUM=\"\$(php -r \"echo hash_file('sha384', 'composer-setup.php');\")\"
    
    if [ \"\$EXPECTED_CHECKSUM\" != \"\$ACTUAL_CHECKSUM\" ]; then
      echo 'ERROR: Invalid installer checksum' >&2
      rm composer-setup.php
      exit 1
    fi
    
    # Install composer
    ${sudo_cmd:-} php composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
    RESULT=\$?
    rm composer-setup.php
    
    exit \$RESULT
  "
  
  local exit_code=$?
  rm -rf "$tmpdir"
  
  if [ $exit_code -ne 0 ]; then
    gum style --foreground 196 "Composer installation failed"
    return $exit_code
  fi
}

install_via_pkg() {
  # Fallback: distro package (may install distro PHP). Kept as a secondary path.
  if declare -f pb_packages >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      pb_packages "Installing Composer (apt)" composer
    elif command -v dnf >/dev/null 2>&1; then
      pb_packages "Installing Composer (dnf)" composer
    fi
  else
    local sudo_cmd
    sudo_cmd=$(need_sudo || true)
    if command -v apt-get >/dev/null 2>&1; then
      gum spin --spinner line --title "Installing Composer (apt)" -- bash -c "${sudo_cmd:-} apt-get update -y >/dev/null 2>&1; ${sudo_cmd:-} apt-get install -y composer >/dev/null 2>&1"
    elif command -v dnf >/dev/null 2>&1; then
      gum spin --spinner line --title "Installing Composer (dnf)" -- bash -c "${sudo_cmd:-} dnf install -y composer >/dev/null 2>&1"
    fi
  fi
}

main() {
  if already_installed; then
    gum style --foreground 82 "Composer already installed"
    composer --version 2>/dev/null | head -n1 | xargs -I{} gum style --foreground 212 --bold {}
    exit 0
  fi

  if command_exists php; then
    install_via_official || exit $?
  else
    # No PHP; safer to ask user to install PHP first than to pull distro PHP implicitly.
    gum style --foreground 214 "PHP CLI not detected; attempting distro package for Composer (may install distro PHP)."
    install_via_pkg || true
  fi

  if already_installed; then
    composer --version 2>/dev/null | head -n1 | xargs -I{} gum style --foreground 212 --bold {}
    
    # Run health check
    run_composer_health_check
  else
    gum style --foreground 196 "Composer installation did not complete."
    exit 2
  fi
}

run_composer_health_check() {
  if ! declare -f health_check_summary >/dev/null 2>&1; then
    log_warn "Health check functions not available, skipping validation"
    return 0
  fi
  
  local checks=(
    "validate_command composer '[0-9]+\\.[0-9]+'"
    "validate_command php 'PHP [0-9]+'"
  )
  
  # Check if composer can access repositories (if internet is available)
  if ping -c 1 packagist.org >/dev/null 2>&1; then
    checks+=("composer diagnose --no-interaction >/dev/null 2>&1 || echo 'Composer diagnose (optional)'")
    checks+=("composer show -p 2>/dev/null | grep -q 'php' || echo 'Packagist connectivity (optional)'")
  fi
  
  # Check composer global directory exists - simplified
  if composer config --global home >/dev/null 2>&1; then
    checks+=("test -d \"\$(composer config --global home 2>/dev/null)\"")
  fi
  
  health_check_summary "Composer" "${checks[@]}"
}

main "$@"
