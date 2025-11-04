#!/usr/bin/env bash
# Laravel .env configuration helper
# Interactive tool to manage Laravel environment variables
set -euo pipefail

# Set component name for logging
export CRUCIBLE_COMPONENT="configure_env"

if ! command -v gum >/dev/null 2>&1; then
  echo "[configure-env][warn] gum not found; proceeding without fancy UI" >&2
  gum() { shift || true; "$@"; }
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }
need_sudo() { if [[ $EUID -ne 0 ]]; then command_exists sudo && echo sudo; fi; }

ENV_FILE=""
PROJECT_PATH=""

# List available Laravel applications
list_laravel_apps() {
  local apps=()

  # Check common locations for Laravel apps
  local search_paths=(
    "/var/www"
    "/srv/www"
    "/home/*/www"
  )

  for base_path in "${search_paths[@]}"; do
    if [[ -d "$base_path" ]]; then
      while IFS= read -r -d '' artisan_file; do
        local app_path
        app_path=$(dirname "$artisan_file")
        # Check if it's actually a Laravel app
        if [[ -f "$app_path/composer.json" ]] && grep -q "laravel/framework" "$app_path/composer.json" 2>/dev/null; then
          apps+=("$app_path")
        fi
      done < <(find "$base_path" -maxdepth 3 -name "artisan" -type f -print0 2>/dev/null)
    fi
  done

  printf '%s\n' "${apps[@]}" | sort -u
}

# Select Laravel application
select_application() {
  clear || true
  gum style --foreground 45 --bold "Laravel Environment Configuration"
  gum style --faint "Manage Laravel .env files interactively"
  echo

  # List available Laravel apps
  local available_apps
  mapfile -t available_apps < <(list_laravel_apps)

  if [[ ${#available_apps[@]} -eq 0 ]]; then
    gum style --foreground 196 "No Laravel applications found"
    gum style --faint "Install a Laravel app first using the Framework menu"
    exit 1
  fi

  # Let user choose or enter custom path
  local app_choices=("${available_apps[@]}" "Enter custom path")
  local selected_app
  selected_app=$(gum choose --header "Select Laravel application" "${app_choices[@]}") || exit 0

  if [[ "$selected_app" == "Enter custom path" ]]; then
    PROJECT_PATH=$(gum input --placeholder "/var/www/example.com" --prompt "Application path: ") || exit 0
  else
    PROJECT_PATH="$selected_app"
  fi

  # Determine .env file location
  if [[ -f "$PROJECT_PATH/.env" ]]; then
    ENV_FILE="$PROJECT_PATH/.env"
  elif [[ -f "$PROJECT_PATH/shared/.env" ]]; then
    ENV_FILE="$PROJECT_PATH/shared/.env"
  elif [[ -f "$PROJECT_PATH/.env.example" ]]; then
    gum style --foreground 214 "No .env file found, but .env.example exists"
    if gum confirm "Create .env from .env.example?"; then
      local sudo_cmd
      sudo_cmd=$(need_sudo || true)
      ${sudo_cmd:-} cp "$PROJECT_PATH/.env.example" "$PROJECT_PATH/.env"
      ENV_FILE="$PROJECT_PATH/.env"
    else
      exit 0
    fi
  else
    gum style --foreground 196 "No .env file or .env.example found"
    exit 1
  fi

  gum style --foreground 82 "Selected: $PROJECT_PATH"
  gum style --faint "Environment file: $ENV_FILE"
  echo
}

# Get current value from .env
get_env_value() {
  local key="$1"
  local value=""

  if [[ -f "$ENV_FILE" ]]; then
    value=$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
  fi

  echo "$value"
}

# Set value in .env
set_env_value() {
  local key="$1"
  local value="$2"
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Escape special characters for sed
  local escaped_value
  escaped_value=$(printf '%s\n' "$value" | sed -e 's/[\/&]/\\&/g')

  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    # Update existing value
    ${sudo_cmd:-} sed -i "s/^${key}=.*/${key}=${escaped_value}/" "$ENV_FILE"
  else
    # Add new value
    echo "${key}=${value}" | ${sudo_cmd:-} tee -a "$ENV_FILE" >/dev/null
  fi
}

# Configure application settings
configure_app_settings() {
  gum style --foreground 212 --bold "Application Settings"
  echo

  # APP_NAME
  local app_name
  app_name=$(get_env_value "APP_NAME")
  local new_app_name
  new_app_name=$(gum input --placeholder "Laravel" --prompt "Application Name: " --value "$app_name") || return 0
  if [[ -n "$new_app_name" ]] && [[ "$new_app_name" != "$app_name" ]]; then
    set_env_value "APP_NAME" "\"$new_app_name\""
  fi

  # APP_ENV
  local app_env
  app_env=$(get_env_value "APP_ENV")
  local new_app_env
  new_app_env=$(gum choose --header "Environment" \
    --selected="$app_env" \
    "production" \
    "local" \
    "staging" \
    "testing") || return 0
  if [[ -n "$new_app_env" ]] && [[ "$new_app_env" != "$app_env" ]]; then
    set_env_value "APP_ENV" "$new_app_env"
  fi

  # APP_DEBUG
  local app_debug
  app_debug=$(get_env_value "APP_DEBUG")
  if [[ "$app_debug" == "true" ]] || gum confirm "Enable debug mode?"; then
    set_env_value "APP_DEBUG" "true"
  else
    set_env_value "APP_DEBUG" "false"
  fi

  # APP_URL
  local app_url
  app_url=$(get_env_value "APP_URL")
  local new_app_url
  new_app_url=$(gum input --placeholder "http://localhost" --prompt "Application URL: " --value "$app_url") || return 0
  if [[ -n "$new_app_url" ]] && [[ "$new_app_url" != "$app_url" ]]; then
    set_env_value "APP_URL" "$new_app_url"
  fi

  gum style --foreground 82 "Application settings updated"
}

# Configure database settings
configure_database() {
  gum style --foreground 212 --bold "Database Configuration"
  echo

  # DB_CONNECTION
  local db_connection
  db_connection=$(get_env_value "DB_CONNECTION")
  local new_db_connection
  new_db_connection=$(gum choose --header "Database Type" \
    --selected="$db_connection" \
    "mysql" \
    "pgsql" \
    "sqlite" \
    "sqlsrv") || return 0
  if [[ -n "$new_db_connection" ]] && [[ "$new_db_connection" != "$db_connection" ]]; then
    set_env_value "DB_CONNECTION" "$new_db_connection"
  fi

  if [[ "$new_db_connection" != "sqlite" ]]; then
    # DB_HOST
    local db_host
    db_host=$(get_env_value "DB_HOST")
    local new_db_host
    new_db_host=$(gum input --placeholder "127.0.0.1" --prompt "Database Host: " --value "$db_host") || return 0
    if [[ -n "$new_db_host" ]]; then
      set_env_value "DB_HOST" "$new_db_host"
    fi

    # DB_PORT
    local db_port
    db_port=$(get_env_value "DB_PORT")
    local default_port="3306"
    [[ "$new_db_connection" == "pgsql" ]] && default_port="5432"
    local new_db_port
    new_db_port=$(gum input --placeholder "$default_port" --prompt "Database Port: " --value "$db_port") || return 0
    if [[ -n "$new_db_port" ]]; then
      set_env_value "DB_PORT" "$new_db_port"
    fi

    # DB_DATABASE
    local db_name
    db_name=$(get_env_value "DB_DATABASE")
    local new_db_name
    new_db_name=$(gum input --placeholder "laravel" --prompt "Database Name: " --value "$db_name") || return 0
    if [[ -n "$new_db_name" ]]; then
      set_env_value "DB_DATABASE" "$new_db_name"
    fi

    # DB_USERNAME
    local db_user
    db_user=$(get_env_value "DB_USERNAME")
    local new_db_user
    new_db_user=$(gum input --placeholder "root" --prompt "Database Username: " --value "$db_user") || return 0
    if [[ -n "$new_db_user" ]]; then
      set_env_value "DB_USERNAME" "$new_db_user"
    fi

    # DB_PASSWORD
    local db_pass
    db_pass=$(get_env_value "DB_PASSWORD")
    gum style --faint "Current password: $([ -n "$db_pass" ] && echo '********' || echo '(empty)')"
    if gum confirm "Update database password?"; then
      local new_db_pass
      new_db_pass=$(gum input --placeholder "password" --password --prompt "Database Password: ") || return 0
      if [[ -n "$new_db_pass" ]]; then
        set_env_value "DB_PASSWORD" "$new_db_pass"
      fi
    fi
  fi

  gum style --foreground 82 "Database configuration updated"
}

# Configure cache and session
configure_cache_session() {
  gum style --foreground 212 --bold "Cache & Session Configuration"
  echo

  # CACHE_DRIVER
  local cache_driver
  cache_driver=$(get_env_value "CACHE_DRIVER")
  local new_cache_driver
  new_cache_driver=$(gum choose --header "Cache Driver" \
    --selected="$cache_driver" \
    "redis" \
    "memcached" \
    "file" \
    "database" \
    "array") || return 0
  if [[ -n "$new_cache_driver" ]]; then
    set_env_value "CACHE_DRIVER" "$new_cache_driver"
  fi

  # SESSION_DRIVER
  local session_driver
  session_driver=$(get_env_value "SESSION_DRIVER")
  local new_session_driver
  new_session_driver=$(gum choose --header "Session Driver" \
    --selected="$session_driver" \
    "redis" \
    "file" \
    "cookie" \
    "database" \
    "memcached") || return 0
  if [[ -n "$new_session_driver" ]]; then
    set_env_value "SESSION_DRIVER" "$new_session_driver"
  fi

  # QUEUE_CONNECTION
  local queue_driver
  queue_driver=$(get_env_value "QUEUE_CONNECTION")
  local new_queue_driver
  new_queue_driver=$(gum choose --header "Queue Driver" \
    --selected="$queue_driver" \
    "redis" \
    "database" \
    "sync" \
    "beanstalkd" \
    "sqs") || return 0
  if [[ -n "$new_queue_driver" ]]; then
    set_env_value "QUEUE_CONNECTION" "$new_queue_driver"
  fi

  # Redis configuration if needed
  if [[ "$new_cache_driver" == "redis" ]] || [[ "$new_session_driver" == "redis" ]] || [[ "$new_queue_driver" == "redis" ]]; then
    echo
    gum style --foreground 214 "Redis configuration"

    local redis_host
    redis_host=$(get_env_value "REDIS_HOST")
    local new_redis_host
    new_redis_host=$(gum input --placeholder "127.0.0.1" --prompt "Redis Host: " --value "$redis_host") || return 0
    if [[ -n "$new_redis_host" ]]; then
      set_env_value "REDIS_HOST" "$new_redis_host"
    fi

    local redis_port
    redis_port=$(get_env_value "REDIS_PORT")
    local new_redis_port
    new_redis_port=$(gum input --placeholder "6379" --prompt "Redis Port: " --value "$redis_port") || return 0
    if [[ -n "$new_redis_port" ]]; then
      set_env_value "REDIS_PORT" "$new_redis_port"
    fi
  fi

  gum style --foreground 82 "Cache & session configuration updated"
}

# Configure mail settings
configure_mail() {
  gum style --foreground 212 --bold "Mail Configuration"
  echo

  # MAIL_MAILER
  local mail_mailer
  mail_mailer=$(get_env_value "MAIL_MAILER")
  local new_mail_mailer
  new_mail_mailer=$(gum choose --header "Mail Driver" \
    --selected="$mail_mailer" \
    "smtp" \
    "sendmail" \
    "mailgun" \
    "ses" \
    "postmark" \
    "log") || return 0
  if [[ -n "$new_mail_mailer" ]]; then
    set_env_value "MAIL_MAILER" "$new_mail_mailer"
  fi

  if [[ "$new_mail_mailer" == "smtp" ]]; then
    # MAIL_HOST
    local mail_host
    mail_host=$(get_env_value "MAIL_HOST")
    local new_mail_host
    new_mail_host=$(gum input --placeholder "smtp.mailtrap.io" --prompt "SMTP Host: " --value "$mail_host") || return 0
    if [[ -n "$new_mail_host" ]]; then
      set_env_value "MAIL_HOST" "$new_mail_host"
    fi

    # MAIL_PORT
    local mail_port
    mail_port=$(get_env_value "MAIL_PORT")
    local new_mail_port
    new_mail_port=$(gum input --placeholder "587" --prompt "SMTP Port: " --value "$mail_port") || return 0
    if [[ -n "$new_mail_port" ]]; then
      set_env_value "MAIL_PORT" "$new_mail_port"
    fi

    # MAIL_USERNAME
    local mail_user
    mail_user=$(get_env_value "MAIL_USERNAME")
    local new_mail_user
    new_mail_user=$(gum input --placeholder "user@example.com" --prompt "SMTP Username: " --value "$mail_user") || return 0
    if [[ -n "$new_mail_user" ]]; then
      set_env_value "MAIL_USERNAME" "$new_mail_user"
    fi

    # MAIL_PASSWORD
    if gum confirm "Update SMTP password?"; then
      local new_mail_pass
      new_mail_pass=$(gum input --placeholder "password" --password --prompt "SMTP Password: ") || return 0
      if [[ -n "$new_mail_pass" ]]; then
        set_env_value "MAIL_PASSWORD" "$new_mail_pass"
      fi
    fi

    # MAIL_ENCRYPTION
    local mail_encryption
    mail_encryption=$(get_env_value "MAIL_ENCRYPTION")
    local new_mail_encryption
    new_mail_encryption=$(gum choose --header "Encryption" \
      --selected="$mail_encryption" \
      "tls" \
      "ssl" \
      "none") || return 0
    if [[ -n "$new_mail_encryption" ]]; then
      set_env_value "MAIL_ENCRYPTION" "$new_mail_encryption"
    fi
  fi

  # MAIL_FROM_ADDRESS
  local mail_from
  mail_from=$(get_env_value "MAIL_FROM_ADDRESS")
  local new_mail_from
  new_mail_from=$(gum input --placeholder "hello@example.com" --prompt "From Address: " --value "$mail_from") || return 0
  if [[ -n "$new_mail_from" ]]; then
    set_env_value "MAIL_FROM_ADDRESS" "$new_mail_from"
  fi

  gum style --foreground 82 "Mail configuration updated"
}

# Generate application key
generate_key() {
  cd "$PROJECT_PATH"

  if ! grep -q "APP_KEY=base64:" "$ENV_FILE" 2>/dev/null; then
    gum style --foreground 214 "No application key found"

    if gum confirm "Generate application key?"; then
      gum spin --spinner line --title "Generating application key" -- \
        php artisan key:generate --no-interaction

      gum style --foreground 82 "Application key generated"
    fi
  else
    gum style --foreground 82 "Application key already exists"

    if gum confirm "Regenerate application key? (This will invalidate existing sessions)"; then
      gum spin --spinner line --title "Regenerating application key" -- \
        php artisan key:generate --force --no-interaction

      gum style --foreground 82 "Application key regenerated"
    fi
  fi
}

# Main menu
main_menu() {
  while true; do
    clear || true
    gum style --foreground 45 --bold "Laravel Environment Configuration"
    gum style --faint "Application: $PROJECT_PATH"
    gum style --faint "Environment file: $ENV_FILE"
    echo

    local choice
    choice=$(gum choose --header "What would you like to configure?" \
      "Application Settings" \
      "Database Configuration" \
      "Cache & Session" \
      "Mail Configuration" \
      "Generate/Regenerate APP_KEY" \
      "View Current .env File" \
      "Back") || break

    case "$choice" in
      "Application Settings")
        configure_app_settings
        ;;
      "Database Configuration")
        configure_database
        ;;
      "Cache & Session")
        configure_cache_session
        ;;
      "Mail Configuration")
        configure_mail
        ;;
      "Generate/Regenerate APP_KEY")
        generate_key
        ;;
      "View Current .env File")
        gum pager < "$ENV_FILE"
        ;;
      "Back")
        break
        ;;
    esac

    echo
    sleep 1
  done
}

# Main
main() {
  select_application
  main_menu

  echo
  gum style --foreground 82 --bold "Environment configuration complete"
  gum style --faint "Remember to clear config cache: php artisan config:cache"
}

main "$@"
