#!/usr/bin/env bash
# Install PHP 8.4 with common extensions on Ubuntu/Debian or Fedora
# Uses Sury repo (Debian/Ubuntu) or Remi modular (Fedora)
# Safe to re-run (idempotent-ish)
set -euo pipefail

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
  echo "[php84][error] Cannot detect OS (missing /etc/os-release)" >&2
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
    local tz
    tz=$(gum input --placeholder "Timezone (e.g. UTC, Europe/Oslo)" --value "$default_tz" || echo "$default_tz")
    echo "$tz"
  else
    echo "$default_tz"
  fi
}

configure_php_ini() {
  local ini_file="$1"
  local timezone="$2"
  [[ -f "$ini_file" ]] || return 0
  local -A settings=(
    [memory_limit]="512M"
    [upload_max_filesize]="64M"
    [post_max_size]="64M"
    [max_execution_time]="120"
    [date.timezone]="$timezone"
  )
  for key in "${!settings[@]}"; do
    if grep -qE "^;?${key}\s*=" "$ini_file"; then
      sed -i "s|^;\?${key}\s*=.*|${key} = ${settings[$key]}|" "$ini_file"
    else
      echo "${key} = ${settings[$key]}" >>"$ini_file"
    fi
  done
}

install_ubuntu() {
  gum spin --spinner line --title "Adding Sury repo" -- bash -c '
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y ca-certificates curl gnupg lsb-release >/dev/null 2>&1
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/keyrings/sury.gpg
    echo "deb [signed-by=/etc/apt/keyrings/sury.gpg] https://packages.sury.org/php/ $(. /etc/os-release && echo $VERSION_CODENAME) main" >/etc/apt/sources.list.d/sury-php.list
    apt-get update -y >/dev/null 2>&1
  '
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing PHP ${PHP_TARGET_MAJOR}" php${PHP_TARGET_MAJOR} "${UBUNTU_PACKAGES[@]}"
  else
    gum spin --spinner line --title "Installing PHP ${PHP_TARGET_MAJOR}" -- bash -c "apt-get install -y php${PHP_TARGET_MAJOR} ${UBUNTU_PACKAGES[*]} >/dev/null 2>&1"
  fi
}

install_fedora() {
  local relpkg="https://rpms.remirepo.net/fedora/remi-release-${DIST_VERSION_ID}.rpm"
  gum spin --spinner line --title "Adding Remi repo" -- bash -c "dnf install -y ${relpkg} >/dev/null 2>&1 || true"
  gum spin --spinner line --title "Enabling PHP ${PHP_TARGET_MAJOR} module" -- bash -c 'dnf -y module reset php >/dev/null 2>&1; dnf -y module enable php:remi-8.4 >/dev/null 2>&1'
  if declare -f pb_packages >/dev/null 2>&1; then
    pb_packages "Installing PHP ${PHP_TARGET_MAJOR}" "${FEDORA_PACKAGES[@]}"
  else
    gum spin --spinner line --title "Installing PHP ${PHP_TARGET_MAJOR}" -- bash -c "dnf install -y ${FEDORA_PACKAGES[*]} >/dev/null 2>&1"
  fi
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
  for ini in /etc/php/${PHP_TARGET_MAJOR}/fpm/php.ini /etc/php/${PHP_TARGET_MAJOR}/cli/php.ini /etc/php.ini; do
    [[ -f $ini ]] && configure_php_ini "$ini" "$tz"
  done

  # Enable and start php-fpm service where applicable
  if systemctl list-unit-files | grep -q php-fpm; then
    gum spin --spinner line --title "Enabling php-fpm" -- bash -c 'systemctl enable php-fpm >/dev/null 2>&1 || true'
    gum spin --spinner line --title "Starting php-fpm" -- bash -c 'systemctl restart php-fpm >/dev/null 2>&1 || true'
  fi

  gum style --foreground 212 --bold "PHP $(php -v | head -n1 | awk '{print $2}') installed"
}

main "$@"
