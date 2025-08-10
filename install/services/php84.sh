#!/usr/bin/env bash
# Install PHP 8.4 with common extensions on Ubuntu/Debian or Fedora
# Uses Sury repo (Debian/Ubuntu) or Remi modular (Fedora)
# Safe to re-run (idempotent-ish)
set -euo pipefail

# Set component name for logging
export CRUCIBLE_COMPONENT="php84"

PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
if [[ -f "$PROGRESS_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$PROGRESS_LIB"
fi

if ! command -v gum >/dev/null 2>&1; then
  echo "[php84][warn] gum not found; proceeding without fancy UI" >&2
  gum() { shift || true; "$@"; }
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }

# Detect distro
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  DIST_ID="${ID,,}"
  DIST_LIKE="${ID_LIKE:-}"; DIST_LIKE="${DIST_LIKE,,}"
  DIST_VERSION_ID="${VERSION_ID:-}";
else
  gum style --foreground 196 "[php84][error] Cannot detect OS (missing /etc/os-release)"
  exit 1
fi

need_sudo() { if [[ $EUID -ne 0 ]]; then [[ $(command -v sudo) ]] && echo sudo || echo ""; fi; }
run() { local pre shellcmd; pre=$(need_sudo); shellcmd="$*"; echo "> $pre $shellcmd"; eval "$pre $shellcmd"; }

PHP_TARGET_MAJOR=8.4
COMMON_EXTS=(cli fpm mysql pdo_mysql opcache curl mbstring intl xml zip bcmath gd soap readline)
UBUNTU_PACKAGES=()
FEDORA_PACKAGES=()

for ext in "${COMMON_EXTS[@]}"; do
  UBUNTU_PACKAGES+=("php${PHP_TARGET_MAJOR}-${ext}")
  # Fedora (module) packages are simply php-<ext> (except core already includes some)
  [[ "$ext" == "cli" ]] && continue
  FEDORA_PACKAGES+=("php-${ext}")
done

# Fix loop termination (typo safeguard) - if above failed, rebuild arrays
if [[ ${#UBUNTU_PACKAGES[@]} -eq 0 ]]; then
  UBUNTU_PACKAGES=("php${PHP_TARGET_MAJOR}" "php${PHP_TARGET_MAJOR}-fpm" "php${PHP_TARGET_MAJOR}-mysql" "php${PHP_TARGET_MAJOR}-mbstring" "php${PHP_TARGET_MAJOR}-xml" "php${PHP_TARGET_MAJOR}-intl" "php${PHP_TARGET_MAJOR}-zip" "php${PHP_TARGET_MAJOR}-gd" "php${PHP_TARGET_MAJOR}-curl" "php${PHP_TARGET_MAJOR}-bcmath" "php${PHP_TARGET_MAJOR}-soap" "php${PHP_TARGET_MAJOR}-opcache")
fi
if [[ ${#FEDORA_PACKAGES[@]} -eq 0 ]]; then
  FEDORA_PACKAGES=(php php-fpm php-mysqlnd php-mbstring php-xml php-intl php-zip php-gd php-curl php-bcmath php-soap php-opcache)
fi

already_correct_version() {
  if command_exists php; then
    local ver
    ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    [[ "$ver" == "${PHP_TARGET_MAJOR}" ]]
  else
    return 1
  fi
}

choose_timezone() {
  local default_tz="UTC"
  if command_exists timedatectl; then
    local sys_tz
    sys_tz=$(timedatectl 2>/dev/null | awk -F': ' '/Time zone/ {print $2}' | awk '{print $1}') || true
    [[ -n "$sys_tz" ]] && default_tz="$sys_tz"
  fi
  
  if command_exists gum; then
    gum style --foreground 45 --bold "PHP Timezone Configuration"
    gum style --faint "Select your timezone for PHP configuration. This affects date/time functions."
    gum style --faint "You can change this later by editing php.ini files manually."
    echo
    
    # Common timezone options
    local timezones=(
      "UTC (Coordinated Universal Time)"
      "America/New_York (US East Coast)"
      "America/Chicago (US Central)"
      "America/Denver (US Mountain)" 
      "America/Los_Angeles (US West Coast)"
      "Europe/London (UK)"
      "Europe/Paris (Central Europe)"
      "Europe/Berlin (Germany)"
      "Europe/Amsterdam (Netherlands)"
      "Europe/Stockholm (Sweden)"
      "Europe/Oslo (Norway)"
      "Asia/Tokyo (Japan)"
      "Asia/Shanghai (China)"
      "Asia/Kolkata (India)"
      "Australia/Sydney (Australia East)"
      "Custom timezone (manual input)"
    )
    
    # Add detected system timezone to top if different from UTC
    if [[ "$default_tz" != "UTC" && "$default_tz" != "" ]]; then
      timezones=("$default_tz (detected system timezone)" "${timezones[@]}")
    fi
    
    local choice
    choice=$(gum choose --header "Choose PHP timezone:" "${timezones[@]}") || {
      echo "$default_tz"
      return
    }
    
    case "$choice" in
      *"detected system timezone"*)
        echo "$default_tz"
        ;;
      "UTC"*)
        echo "UTC"
        ;;
      "America/New_York"*)
        echo "America/New_York"
        ;;
      "America/Chicago"*)
        echo "America/Chicago"
        ;;
      "America/Denver"*)
        echo "America/Denver"
        ;;
      "America/Los_Angeles"*)
        echo "America/Los_Angeles"
        ;;
      "Europe/London"*)
        echo "Europe/London"
        ;;
      "Europe/Paris"*)
        echo "Europe/Paris"
        ;;
      "Europe/Berlin"*)
        echo "Europe/Berlin"
        ;;
      "Europe/Amsterdam"*)
        echo "Europe/Amsterdam"
        ;;
      "Europe/Stockholm"*)
        echo "Europe/Stockholm"
        ;;
      "Europe/Oslo"*)
        echo "Europe/Oslo"
        ;;
      "Asia/Tokyo"*)
        echo "Asia/Tokyo"
        ;;
      "Asia/Shanghai"*)
        echo "Asia/Shanghai"
        ;;
      "Asia/Kolkata"*)
        echo "Asia/Kolkata"
        ;;
      "Australia/Sydney"*)
        echo "Australia/Sydney"
        ;;
      "Custom timezone"*)
        gum style --faint "Enter custom timezone (e.g. Asia/Dubai, Pacific/Auckland):"
        gum input --placeholder "Custom timezone" --value "$default_tz" || echo "$default_tz"
        ;;
      *)
        echo "$default_tz"
        ;;
    esac
  else
    echo "$default_tz"
  fi
}

configure_php_ini() {
  local ini_file="$1"
  local timezone="$2"
  [[ -f "$ini_file" ]] || return 0
  
  # Backup the original ini file if backup function is available
  if declare -f backup_file >/dev/null 2>&1; then
    backup_file "$ini_file" || gum style --foreground 214 "Warning: Could not backup $ini_file"
  fi
  
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  local -A settings=(
    [memory_limit]="512M"
    [upload_max_filesize]="64M"
    [post_max_size]="64M"
    [max_execution_time]="120"
    [date.timezone]="$timezone"
  )
  
  for key in "${!settings[@]}"; do
    local value="${settings[$key]}"
    if grep -qE "^;?${key}\s*=" "$ini_file"; then
      # Use a safe delimiter that won't conflict with timezone paths or other values
      # Escape any forward slashes in the value for sed
      local escaped_value="${value//\//\\/}"
      ${sudo_cmd:-} sed -i "s/^;\?${key}\s*=.*/${key} = ${escaped_value}/" "$ini_file"
    else
      echo "${key} = ${value}" | ${sudo_cmd:-} tee -a "$ini_file" >/dev/null
    fi
  done
}

install_ubuntu() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  gum spin --spinner line --title "Adding Sury repo" -- bash -c "
    ${sudo_cmd:-} apt-get update -y >/dev/null 2>&1 || true
    ${sudo_cmd:-} apt-get install -y ca-certificates curl gnupg lsb-release >/dev/null 2>&1
    ${sudo_cmd:-} install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg | ${sudo_cmd:-} tee /etc/apt/keyrings/sury.gpg >/dev/null
    echo \"deb [signed-by=/etc/apt/keyrings/sury.gpg] https://packages.sury.org/php/ \$(. /etc/os-release && echo \$VERSION_CODENAME) main\" | ${sudo_cmd:-} tee /etc/apt/sources.list.d/sury-php.list >/dev/null
    ${sudo_cmd:-} apt-get update -y >/dev/null 2>&1
  "
  
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing PHP ${PHP_TARGET_MAJOR}" php${PHP_TARGET_MAJOR} "${UBUNTU_PACKAGES[@]}"
  else
    gum spin --spinner line --title "Installing PHP ${PHP_TARGET_MAJOR}" -- bash -c "${sudo_cmd:-} apt-get install -y php${PHP_TARGET_MAJOR} ${UBUNTU_PACKAGES[*]} >/dev/null 2>&1"
  fi
}

install_fedora() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  local relpkg="https://rpms.remirepo.net/fedora/remi-release-${DIST_VERSION_ID}.rpm"
  gum spin --spinner line --title "Adding Remi repo" -- bash -c "${sudo_cmd:-} dnf install -y ${relpkg} >/dev/null 2>&1 || true"
  gum spin --spinner line --title "Enabling PHP ${PHP_TARGET_MAJOR} module" -- bash -c "${sudo_cmd:-} dnf -y module reset php >/dev/null 2>&1; ${sudo_cmd:-} dnf -y module enable php:remi-8.4 >/dev/null 2>&1"
  
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing PHP ${PHP_TARGET_MAJOR}" "${FEDORA_PACKAGES[@]}"
  else
    gum spin --spinner line --title "Installing PHP ${PHP_TARGET_MAJOR}" -- bash -c "${sudo_cmd:-} dnf install -y ${FEDORA_PACKAGES[*]} >/dev/null 2>&1"
  fi
}

run_php_health_check() {
  if ! declare -f health_check_summary >/dev/null 2>&1; then
    log_warn "Health check functions not available, skipping validation"
    return 0
  fi
  
  local checks=(
    "validate_command php '8\\.4'"
    "validate_command php-fpm '8\\.4'"
  )
  
  # Add service checks if systemd is available
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q php-fpm; then
    checks+=(
      "validate_service_enabled php-fpm"
      "validate_service_running php-fpm"
    )
  fi
  
  # Check for essential PHP extensions
  local essential_exts=(mbstring xml curl json)
  for ext in "${essential_exts[@]}"; do
    checks+=("php -m | grep -q '^$ext$'")
  done
  
  health_check_summary "PHP ${PHP_TARGET_MAJOR}" "${checks[@]}"
}

main() {
  if already_correct_version; then
    gum style --foreground 82 "PHP ${PHP_TARGET_MAJOR} already installed"
  else
    case "$DIST_ID" in
      ubuntu|debian)
        install_ubuntu ;;
      fedora)
        install_fedora ;;
      *)
        if [[ "$DIST_LIKE" == *"debian"* ]]; then install_ubuntu
        elif [[ "$DIST_LIKE" == *"fedora"* || "$DIST_LIKE" == *"rhel"* ]]; then install_fedora
        else
          gum style --foreground 196 "Unsupported distribution: $DIST_ID"
          exit 2
        fi
        ;;
    esac
  fi

  local tz
  tz=$(choose_timezone)
  
  # Attempt common ini locations
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  local configured_files=()
  for ini in /etc/php/${PHP_TARGET_MAJOR}/fpm/php.ini /etc/php/${PHP_TARGET_MAJOR}/cli/php.ini /etc/php.ini; do
    if [[ -f $ini ]]; then
      configure_php_ini "$ini" "$tz"
      configured_files+=("$ini")
    fi
  done
  
  # Show user where timezone was configured
  if [[ ${#configured_files[@]} -gt 0 ]]; then
    echo
    gum style --foreground 82 "PHP timezone set to: $tz"
    gum style --faint "To change timezone later, edit these files:"
    for file in "${configured_files[@]}"; do
      gum style --faint "  • $file"
    done
    gum style --faint "Look for: date.timezone = $tz"
    echo
  fi

  # Enable and start php-fpm service where applicable
  if systemctl list-unit-files | grep -q php-fpm; then
    gum spin --spinner line --title "Enabling php-fpm" -- bash -c "${sudo_cmd:-} systemctl enable php-fpm >/dev/null 2>&1 || true"
    gum spin --spinner line --title "Starting php-fpm" -- bash -c "${sudo_cmd:-} systemctl restart php-fpm >/dev/null 2>&1 || true"
  fi

  gum style --foreground 212 --bold "PHP $(php -v | head -n1 | awk '{print $2}') installed"
  
  # Run health check
  run_php_health_check
}

main "$@"
