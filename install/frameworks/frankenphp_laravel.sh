#!/usr/bin/env bash
# Laravel application installer with FrankenPHP configuration
# Native Laravel Octane support with worker mode for maximum performance
# FrankenPHP handles PHP execution directly - no PHP-FPM needed
set -euo pipefail

# Set component name for logging
export CRUCIBLE_COMPONENT="frankenphp_laravel"

# Load progress library if present
PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"

if ! command -v gum >/dev/null 2>&1; then
  echo "[frankenphp-laravel][warn] gum not found; proceeding without UI prompts" >&2
  gum() { shift || true; "$@"; }
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }
need_sudo() { if [[ $EUID -ne 0 ]]; then command_exists sudo && echo sudo; fi; }

# Default values
PROJECT_NAME=""
DOMAIN=""
PROJECT_PATH=""
REPOSITORY=""
BRANCH="main"
FORCE_INSTALL=false
UPDATE_EXISTING=false
CONFIGURE_SUPERVISOR=false
QUEUE_WORKERS=1
ENABLE_HTTPS=true
ENABLE_OCTANE=false
OCTANE_WORKERS=4

# Interactive user input using gum
get_user_input() {
  clear || true
  gum style --foreground 45 --bold "Laravel + FrankenPHP Application Setup"
  gum style --faint "FrankenPHP: Modern PHP server with native Laravel Octane support"
  gum style --faint "Built on Caddy with automatic HTTPS and worker mode"
  echo

  # Installation type selection
  local install_type
  install_type=$(gum choose --header "What would you like to do?" \
    "Create new Laravel project" \
    "Clone from Git repository" \
    "Update existing application" \
    "Cancel") || exit 0

  case "$install_type" in
    "Cancel") exit 0 ;;
    "Update existing application") UPDATE_EXISTING=true ;;
    "Clone from Git repository") ;;
    "Create new Laravel project") ;;
  esac

  # Get domain (required for all types)
  while [[ -z "$DOMAIN" ]]; do
    DOMAIN=$(gum input --placeholder "Enter domain name (e.g. example.com)" --prompt "Domain: ") || exit 0
    if [[ -z "$DOMAIN" ]]; then
      gum style --foreground 196 "Domain is required!"
      echo
    fi
  done

  if [[ "$UPDATE_EXISTING" == "true" ]]; then
    # For updates, try to auto-detect project path
    local default_path="/var/www/$DOMAIN"
    PROJECT_PATH=$(gum input --placeholder "$default_path" --prompt "Project Path: " --value "$default_path") || exit 0
    if [[ -z "$PROJECT_PATH" ]]; then
      PROJECT_PATH="$default_path"
    fi
  elif [[ "$install_type" == "Clone from Git repository" ]]; then
    # Get repository URL
    while [[ -z "$REPOSITORY" ]]; do
      REPOSITORY=$(gum input --placeholder "https://github.com/user/repository.git" --prompt "Repository URL: ") || exit 0
      if [[ -z "$REPOSITORY" ]]; then
        gum style --foreground 196 "Repository URL is required!"
        echo
      fi
    done

    # Get branch (optional)
    BRANCH=$(gum input --placeholder "main" --prompt "Branch (optional): " --value "main") || exit 0
    if [[ -z "$BRANCH" ]]; then
      BRANCH="main"
    fi

    # Get project path (optional)
    local default_path="/var/www/$DOMAIN"
    PROJECT_PATH=$(gum input --placeholder "$default_path" --prompt "Installation path (optional): " --value "$default_path") || exit 0
    if [[ -z "$PROJECT_PATH" ]]; then
      PROJECT_PATH="$default_path"
    fi
  else
    # New Laravel project
    while [[ -z "$PROJECT_NAME" ]]; do
      PROJECT_NAME=$(gum input --placeholder "myapp" --prompt "Project Name: ") || exit 0
      if [[ -z "$PROJECT_NAME" ]]; then
        gum style --foreground 196 "Project name is required!"
        echo
      fi
    done

    # Get project path (optional)
    local default_path="/var/www/$DOMAIN"
    PROJECT_PATH=$(gum input --placeholder "$default_path" --prompt "Installation path (optional): " --value "$default_path") || exit 0
    if [[ -z "$PROJECT_PATH" ]]; then
      PROJECT_PATH="$default_path"
    fi
  fi

  # Advanced options
  echo
  if gum confirm "Configure advanced options?"; then
    if [[ -d "$PROJECT_PATH" ]] && [[ "$UPDATE_EXISTING" == "false" ]]; then
      if gum confirm "Directory $PROJECT_PATH already exists. Force overwrite?"; then
        FORCE_INSTALL=true
      fi
    fi

    # Ask about HTTPS
    if ! gum confirm "Enable automatic HTTPS with Let's Encrypt?"; then
      ENABLE_HTTPS=false
    fi

    # Ask about Laravel Octane
    if gum confirm "Enable Laravel Octane for maximum performance? (Recommended)"; then
      ENABLE_OCTANE=true
      # Get number of Octane workers
      local workers_input
      workers_input=$(gum input --placeholder "4" --prompt "Number of Octane workers: " --value "4") || true
      if [[ -n "$workers_input" ]] && [[ "$workers_input" =~ ^[0-9]+$ ]]; then
        OCTANE_WORKERS="$workers_input"
      fi
    fi

    # Ask about Supervisor for queue workers (only if not using Octane)
    if [[ "$ENABLE_OCTANE" == "false" ]] && command_exists supervisord; then
      if gum confirm "Configure Supervisor for Laravel queue workers?"; then
        CONFIGURE_SUPERVISOR=true
        # Get number of queue workers
        local workers_input
        workers_input=$(gum input --placeholder "1" --prompt "Number of queue workers: " --value "1") || true
        if [[ -n "$workers_input" ]] && [[ "$workers_input" =~ ^[0-9]+$ ]]; then
          QUEUE_WORKERS="$workers_input"
        fi
      fi
    elif [[ "$ENABLE_OCTANE" == "false" ]]; then
      gum style --faint "Tip: Install Supervisor to manage Laravel queue workers"
    fi
  fi

  # Summary
  echo
  gum style --foreground 82 --bold "Configuration Summary:"
  gum style --faint "Domain: $DOMAIN"
  [[ -n "$PROJECT_NAME" ]] && gum style --faint "Project Name: $PROJECT_NAME"
  [[ -n "$REPOSITORY" ]] && gum style --faint "Repository: $REPOSITORY"
  [[ -n "$BRANCH" && "$BRANCH" != "main" ]] && gum style --faint "Branch: $BRANCH"
  gum style --faint "Installation Path: $PROJECT_PATH"
  [[ "$UPDATE_EXISTING" == "true" ]] && gum style --faint "Mode: Update existing"
  [[ "$FORCE_INSTALL" == "true" ]] && gum style --faint "Force overwrite: Yes"
  [[ "$ENABLE_HTTPS" == "true" ]] && gum style --faint "HTTPS: Automatic (Let's Encrypt)"
  [[ "$ENABLE_HTTPS" == "false" ]] && gum style --faint "HTTPS: Disabled (HTTP only)"
  [[ "$ENABLE_OCTANE" == "true" ]] && gum style --faint "Laravel Octane: Enabled ($OCTANE_WORKERS workers)"
  [[ "$CONFIGURE_SUPERVISOR" == "true" ]] && gum style --faint "Supervisor Queue Workers: $QUEUE_WORKERS"
  echo

  if ! gum confirm "Proceed with installation?"; then
    gum style --foreground 214 "Installation cancelled"
    exit 0
  fi
}

# Check if FrankenPHP is installed
check_frankenphp_installed() {
  if ! command_exists frankenphp; then
    gum style --foreground 196 --bold "ERROR: FrankenPHP is not installed!"
    gum style --faint "Please install FrankenPHP first using:"
    gum style --faint "  ./install/services/frankenphp.sh"
    gum style --faint "Or through the Core Services menu"
    exit 1
  fi

  # Check if FrankenPHP is running
  if ! systemctl is-active --quiet frankenphp 2>/dev/null; then
    if declare -f log_warn >/dev/null 2>&1; then
      log_warn "FrankenPHP is installed but not running. Attempting to start..."
    fi
    local sudo_cmd
    sudo_cmd=$(need_sudo || true)
    ${sudo_cmd:-} systemctl start frankenphp || {
      gum style --foreground 196 "Failed to start FrankenPHP service"
      exit 1
    }
  fi
}

# Validate requirements
validate_requirements() {
  local missing_deps=()

  # Check for PHP (needed for Composer and Artisan)
  if ! command_exists php; then
    missing_deps+=("PHP")
  fi

  # Check for Composer
  if ! command_exists composer; then
    missing_deps+=("Composer")
  fi

  # Check for git if repository is specified
  if [[ -n "$REPOSITORY" ]] && ! command_exists git; then
    missing_deps+=("Git")
  fi

  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    gum style --foreground 196 --bold "Missing required dependencies: ${missing_deps[*]}"
    gum style --faint "Please install the missing dependencies first."
    gum style --faint "Tip: Use the Core Services installer"
    exit 1
  fi
}

# Validate user input (called after get_user_input)
validate_arguments() {
  # Domain is already validated in get_user_input with required loop

  # Validate project name for new installations
  if [[ "$UPDATE_EXISTING" == "false" ]] && [[ -z "$REPOSITORY" ]] && [[ -z "$PROJECT_NAME" ]]; then
    gum style --foreground 196 "Error: Project name is required for new Laravel installations"
    exit 1
  fi

  # Check if project already exists (unless force or update)
  if [[ -d "$PROJECT_PATH" ]] && [[ "$UPDATE_EXISTING" == "false" ]] && [[ "$FORCE_INSTALL" == "false" ]]; then
    gum style --foreground 196 "Error: Directory $PROJECT_PATH already exists"
    gum style --faint "Use 'Configure advanced options' to force overwrite, or choose 'Update existing application'"
    exit 1
  fi
}

# Check if Laravel application is already configured
is_laravel_configured() {
  [[ -f "$PROJECT_PATH/artisan" ]] && [[ -f "$PROJECT_PATH/composer.json" ]]
}

# Check if FrankenPHP configuration already exists
is_frankenphp_configured() {
  local config_file="/etc/frankenphp/conf.d/${DOMAIN}.caddy"
  [[ -f "$config_file" ]] && grep -q "root.*${PROJECT_PATH}/public" "$config_file" 2>/dev/null
}

# Install new Laravel application
install_new_laravel() {
  if declare -f log_info >/dev/null 2>&1; then
    log_info "Installing new Laravel application"
    log_info "Project path: $PROJECT_PATH"
  fi

  local parent_dir
  parent_dir=$(dirname "$PROJECT_PATH")
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Create parent directory if it doesn't exist
  if [[ ! -d "$parent_dir" ]]; then
    ${sudo_cmd:-} mkdir -p "$parent_dir"
  fi

  # Install Laravel using Composer
  if [[ -n "$PROJECT_NAME" ]]; then
    gum spin --spinner line --title "Creating new Laravel project: $PROJECT_NAME" -- \
      composer create-project laravel/laravel "$PROJECT_PATH" --prefer-dist --no-dev
  else
    echo "Error: Project name required for new Laravel installation" >&2
    exit 1
  fi
}

# Clone repository
clone_repository() {
  if [[ -z "$REPOSITORY" ]]; then
    return 0
  fi

  if declare -f log_info >/dev/null 2>&1; then
    log_info "Cloning repository: $REPOSITORY"
    log_info "Branch: $BRANCH"
    log_info "Target: $PROJECT_PATH"
  fi

  local parent_dir
  parent_dir=$(dirname "$PROJECT_PATH")
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Create parent directory if it doesn't exist
  if [[ ! -d "$parent_dir" ]]; then
    ${sudo_cmd:-} mkdir -p "$parent_dir"
  fi

  # Remove existing directory if force install
  if [[ "$FORCE_INSTALL" == "true" ]] && [[ -d "$PROJECT_PATH" ]]; then
    ${sudo_cmd:-} rm -rf "$PROJECT_PATH"
  fi

  # Clone repository
  gum spin --spinner line --title "Cloning repository" -- \
    git clone --branch "$BRANCH" "$REPOSITORY" "$PROJECT_PATH"
}

# Update existing installation
update_existing_laravel() {
  if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "Error: Project directory $PROJECT_PATH does not exist" >&2
    exit 1
  fi

  if declare -f log_info >/dev/null 2>&1; then
    log_info "Updating existing Laravel installation: $PROJECT_PATH"
  fi

  cd "$PROJECT_PATH"

  # Update from repository if it's a git repo
  if [[ -d ".git" ]] && [[ -n "$REPOSITORY" ]]; then
    gum spin --spinner line --title "Pulling latest changes from repository" -- \
      git pull origin "$BRANCH"
  fi
}

# Install Composer dependencies
install_composer_dependencies() {
  if [[ ! -f "$PROJECT_PATH/composer.json" ]]; then
    if declare -f log_warn >/dev/null 2>&1; then
      log_warn "No composer.json found in $PROJECT_PATH - skipping dependency installation"
    fi
    return 0
  fi

  if declare -f log_info >/dev/null 2>&1; then
    log_info "Installing Composer dependencies"
  fi

  cd "$PROJECT_PATH"

  # Install dependencies (production mode for new installations)
  if [[ "$UPDATE_EXISTING" == "true" ]]; then
    gum spin --spinner line --title "Updating Composer dependencies" -- \
      composer install --optimize-autoloader
  else
    gum spin --spinner line --title "Installing Composer dependencies" -- \
      composer install --no-dev --optimize-autoloader
  fi

  # Install Laravel Octane if enabled
  if [[ "$ENABLE_OCTANE" == "true" ]]; then
    gum spin --spinner line --title "Installing Laravel Octane with FrankenPHP driver" -- \
      composer require laravel/octane --with-all-dependencies
  fi
}

# Setup Laravel application
setup_laravel_app() {
  cd "$PROJECT_PATH"

  # Copy .env file if it doesn't exist
  if [[ ! -f ".env" ]] && [[ -f ".env.example" ]]; then
    if declare -f log_info >/dev/null 2>&1; then
      log_info "Creating .env file from .env.example"
    fi
    cp ".env.example" ".env"
  fi

  # Generate application key if not set
  if [[ -f ".env" ]] && ! grep -q "APP_KEY=base64:" ".env"; then
    if declare -f log_info >/dev/null 2>&1; then
      log_info "Generating Laravel application key"
    fi
    gum spin --spinner line --title "Generating application key" -- \
      php artisan key:generate --no-interaction
  fi

  # Configure Octane if enabled
  if [[ "$ENABLE_OCTANE" == "true" ]]; then
    if declare -f log_info >/dev/null 2>&1; then
      log_info "Configuring Laravel Octane with FrankenPHP"
    fi

    # Publish Octane config if it doesn't exist
    if [[ ! -f "config/octane.php" ]]; then
      gum spin --spinner line --title "Publishing Octane configuration" -- \
        php artisan octane:install --server=frankenphp --no-interaction
    fi

    # Update .env for Octane
    if [[ -f ".env" ]]; then
      # Add or update Octane settings
      if ! grep -q "OCTANE_SERVER" ".env"; then
        echo "OCTANE_SERVER=frankenphp" >> ".env"
      fi
    fi
  fi

  # Set proper permissions
  setup_permissions
}

# Setup proper file permissions
setup_permissions() {
  if declare -f log_info >/dev/null 2>&1; then
    log_info "Setting up file permissions"
  fi

  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Create storage and cache directories if they don't exist
  for dir in storage/logs storage/framework/cache storage/framework/sessions storage/framework/views bootstrap/cache; do
    if [[ ! -d "$PROJECT_PATH/$dir" ]]; then
      ${sudo_cmd:-} mkdir -p "$PROJECT_PATH/$dir"
    fi
  done

  # Set ownership to frankenphp user
  local web_user="frankenphp"
  if ! id frankenphp >/dev/null 2>&1; then
    web_user="www-data"
  fi

  if id "$web_user" >/dev/null 2>&1; then
    ${sudo_cmd:-} chown -R "$web_user:$web_user" "$PROJECT_PATH" || true
  fi

  # Set proper permissions for Laravel
  ${sudo_cmd:-} chmod -R 755 "$PROJECT_PATH" || true
  ${sudo_cmd:-} chmod -R 775 "$PROJECT_PATH/storage" "$PROJECT_PATH/bootstrap/cache" || true
}

# Create FrankenPHP configuration
create_frankenphp_config() {
  local config_file="/etc/frankenphp/conf.d/${DOMAIN}.caddy"
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  if declare -f log_info >/dev/null 2>&1; then
    log_info "Creating FrankenPHP configuration: $config_file"
  fi

  # Check if configuration already exists and is correct (idempotent)
  if is_frankenphp_configured; then
    if declare -f log_info >/dev/null 2>&1; then
      log_info "FrankenPHP configuration already exists and is correct"
    fi
    return 0
  fi

  # Backup existing configuration if it exists
  if [[ -f "$config_file" ]]; then
    if declare -f backup_file >/dev/null 2>&1; then
      backup_file "$config_file"
    else
      local backup_suffix=".bak.$(date +%Y%m%d%H%M%S)"
      ${sudo_cmd:-} cp "$config_file" "${config_file}${backup_suffix}" || true
    fi
  fi

  # Create FrankenPHP configuration
  if [[ "$ENABLE_OCTANE" == "true" ]]; then
    # Octane configuration with worker mode
    if [[ "$ENABLE_HTTPS" == "true" ]]; then
      cat <<EOF | ${sudo_cmd:-} tee "$config_file" >/dev/null
$DOMAIN {
    root * $PROJECT_PATH/public
    encode gzip

    # Laravel Octane with FrankenPHP worker mode
    php {
        root $PROJECT_PATH/public
        # Worker mode with ${OCTANE_WORKERS} workers
        num_threads ${OCTANE_WORKERS}
    }

    file_server

    log {
        output file /var/log/frankenphp/${DOMAIN}.log
        format json
    }
}
EOF
    else
      # HTTP only
      cat <<EOF | ${sudo_cmd:-} tee "$config_file" >/dev/null
http://$DOMAIN {
    root * $PROJECT_PATH/public
    encode gzip

    # Laravel Octane with FrankenPHP worker mode
    php {
        root $PROJECT_PATH/public
        # Worker mode with ${OCTANE_WORKERS} workers
        num_threads ${OCTANE_WORKERS}
    }

    file_server

    log {
        output file /var/log/frankenphp/${DOMAIN}.log
        format json
    }
}
EOF
    fi
  else
    # Standard PHP configuration (no Octane)
    if [[ "$ENABLE_HTTPS" == "true" ]]; then
      cat <<EOF | ${sudo_cmd:-} tee "$config_file" >/dev/null
$DOMAIN {
    root * $PROJECT_PATH/public
    encode gzip

    php {
        root $PROJECT_PATH/public
    }

    file_server

    log {
        output file /var/log/frankenphp/${DOMAIN}.log
        format json
    }
}
EOF
    else
      # HTTP only
      cat <<EOF | ${sudo_cmd:-} tee "$config_file" >/dev/null
http://$DOMAIN {
    root * $PROJECT_PATH/public
    encode gzip

    php {
        root $PROJECT_PATH/public
    }

    file_server

    log {
        output file /var/log/frankenphp/${DOMAIN}.log
        format json
    }
}
EOF
    fi
  fi

  # Reload FrankenPHP
  gum spin --spinner line --title "Reloading FrankenPHP configuration" -- \
    bash -c "${sudo_cmd:-} frankenphp reload --config /etc/frankenphp/Caddyfile"
}

# Configure Supervisor for Laravel queue workers
configure_supervisor() {
  if [[ "$CONFIGURE_SUPERVISOR" != "true" ]]; then
    return 0
  fi

  if ! command_exists supervisord; then
    if declare -f log_warn >/dev/null 2>&1; then
      log_warn "Supervisor not installed, skipping queue worker configuration"
    fi
    return 0
  fi

  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Create a safe program name from domain (replace dots and special chars)
  local program_name
  program_name="laravel-worker-${DOMAIN//[^a-zA-Z0-9]/-}"
  local config_file="/etc/supervisor/conf.d/${program_name}.conf"

  if declare -f log_info >/dev/null 2>&1; then
    log_info "Configuring Supervisor for Laravel queue workers"
    log_info "Program name: $program_name"
    log_info "Workers: $QUEUE_WORKERS"
  fi

  # Determine the user to run the queue worker
  local run_user="frankenphp"
  if ! id frankenphp >/dev/null 2>&1; then
    run_user="www-data"
  fi

  # Backup existing configuration if it exists
  if [[ -f "$config_file" ]]; then
    if declare -f backup_file >/dev/null 2>&1; then
      backup_file "$config_file"
    else
      local backup_suffix=".bak.$(date +%Y%m%d%H%M%S)"
      ${sudo_cmd:-} cp "$config_file" "${config_file}${backup_suffix}" || true
    fi
  fi

  # Create Supervisor configuration for Laravel queue worker
  cat <<EOF | ${sudo_cmd:-} tee "$config_file" >/dev/null
[program:$program_name]
process_name=%(program_name)s_%(process_num)02d
command=php $PROJECT_PATH/artisan queue:work --sleep=3 --tries=3 --max-time=3600
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=$run_user
numprocs=$QUEUE_WORKERS
redirect_stderr=true
stdout_logfile=$PROJECT_PATH/storage/logs/worker.log
stopwaitsecs=3600
EOF

  # Reload Supervisor configuration
  gum spin --spinner line --title "Reloading Supervisor configuration" -- bash -c "
    ${sudo_cmd:-} supervisorctl reread >/dev/null 2>&1
    ${sudo_cmd:-} supervisorctl update >/dev/null 2>&1
    ${sudo_cmd:-} supervisorctl start ${program_name}:* >/dev/null 2>&1 || true
  "

  # Display status
  if declare -f log_info >/dev/null 2>&1; then
    log_info "Supervisor configured successfully"
    log_info "Check status with: supervisorctl status ${program_name}:*"
  fi
}

# Run health checks
run_frankenphp_laravel_health_check() {
  if ! declare -f health_check_summary >/dev/null 2>&1; then
    if declare -f log_warn >/dev/null 2>&1; then
      log_warn "Health check functions not available, skipping validation"
    fi
    return 0
  fi

  cd "$PROJECT_PATH"

  local checks=(
    "test -f '$PROJECT_PATH/composer.json'"
    "test -f '$PROJECT_PATH/artisan'"
    "test -f '$PROJECT_PATH/.env'"
    "test -d '$PROJECT_PATH/storage'"
    "test -d '$PROJECT_PATH/bootstrap/cache'"
    "test -w '$PROJECT_PATH/storage'"
    "test -w '$PROJECT_PATH/bootstrap/cache'"
    "test -f '/etc/frankenphp/conf.d/${DOMAIN}.caddy'"
    "systemctl is-active --quiet frankenphp"
  )

  # Check if Laravel is properly configured
  if grep -q "APP_KEY=base64:" "$PROJECT_PATH/.env" 2>/dev/null; then
    checks+=("grep -q 'APP_KEY=base64:' '$PROJECT_PATH/.env'")
  fi

  # Check if we can run artisan commands
  checks+=("php '$PROJECT_PATH/artisan' --version >/dev/null 2>&1")

  # Check Octane if enabled
  if [[ "$ENABLE_OCTANE" == "true" ]]; then
    checks+=("test -f '$PROJECT_PATH/config/octane.php'")
  fi

  # Check Supervisor if configured
  if [[ "$CONFIGURE_SUPERVISOR" == "true" ]] && command_exists supervisorctl; then
    local program_name="laravel-worker-${DOMAIN//[^a-zA-Z0-9]/-}"
    checks+=("supervisorctl status ${program_name}:* >/dev/null 2>&1")
  fi

  health_check_summary "Laravel + FrankenPHP" "${checks[@]}"
}

# Main execution
main() {
  check_frankenphp_installed
  validate_requirements
  get_user_input
  validate_arguments

  if declare -f log_info >/dev/null 2>&1; then
    log_info "Laravel FrankenPHP installer starting"
    log_info "Domain: $DOMAIN"
    log_info "Project path: $PROJECT_PATH"
    [[ -n "$REPOSITORY" ]] && log_info "Repository: $REPOSITORY"
  fi

  # Check if already configured
  if is_laravel_configured && is_frankenphp_configured && [[ "$FORCE_INSTALL" == "false" ]] && [[ "$UPDATE_EXISTING" == "false" ]]; then
    gum style --foreground 82 "Laravel application already configured for $DOMAIN"
    gum style --faint "Choose 'Update existing application' or use advanced options to force overwrite"
    exit 0
  fi

  if [[ "$UPDATE_EXISTING" == "true" ]]; then
    update_existing_laravel
  elif [[ -n "$REPOSITORY" ]]; then
    clone_repository
  else
    install_new_laravel
  fi

  install_composer_dependencies
  setup_laravel_app
  create_frankenphp_config
  configure_supervisor

  # Summary and important notice
  gum style --foreground 82 --bold "Laravel + FrankenPHP installation complete!"
  echo
  if [[ "$ENABLE_HTTPS" == "true" ]]; then
    gum style --foreground 212 --bold "🔒 Automatic HTTPS Enabled!"
    gum style --foreground 82 "FrankenPHP will automatically obtain and renew SSL certificates"
  fi

  if [[ "$ENABLE_OCTANE" == "true" ]]; then
    echo
    gum style --foreground 212 --bold "⚡ Laravel Octane Enabled!"
    gum style --foreground 82 "Your application is running in worker mode with ${OCTANE_WORKERS} workers"
    gum style --faint "This provides significantly better performance than traditional PHP"
  fi

  echo
  gum style --foreground 214 "IMPORTANT: Ensure DNS is configured:"
  gum style --faint "• Point $DOMAIN to this server's IP: $(curl -s ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")"
  gum style --faint "• Wait for DNS propagation (may take a few minutes)"
  [[ "$ENABLE_HTTPS" == "true" ]] && gum style --faint "• Access: https://$DOMAIN (SSL automatic)"
  [[ "$ENABLE_HTTPS" == "false" ]] && gum style --faint "• Access: http://$DOMAIN"

  echo
  gum style --faint "Application Details:"
  gum style --faint "• Domain: $DOMAIN"
  gum style --faint "• Path: $PROJECT_PATH"
  gum style --faint "• Config: /etc/frankenphp/conf.d/${DOMAIN}.caddy"
  [[ "$ENABLE_HTTPS" == "true" ]] && gum style --faint "• Public URL: https://$DOMAIN"
  [[ "$ENABLE_HTTPS" == "false" ]] && gum style --faint "• Public URL: http://$DOMAIN"

  if [[ "$ENABLE_OCTANE" == "true" ]]; then
    echo
    gum style --foreground 82 --bold "Laravel Octane Commands:"
    gum style --faint "• Reload workers: sudo systemctl reload frankenphp"
    gum style --faint "• Check status: sudo systemctl status frankenphp"
    gum style --faint "• View logs: sudo journalctl -u frankenphp -f"
  fi

  if [[ "$CONFIGURE_SUPERVISOR" == "true" ]]; then
    echo
    gum style --foreground 82 --bold "Supervisor Queue Workers Configured:"
    local program_name="laravel-worker-${DOMAIN//[^a-zA-Z0-9]/-}"
    gum style --faint "• Workers: $QUEUE_WORKERS"
    gum style --faint "• Check status: sudo supervisorctl status ${program_name}:*"
    gum style --faint "• Restart workers: sudo supervisorctl restart ${program_name}:*"
    gum style --faint "• Logs: $PROJECT_PATH/storage/logs/worker.log"
  fi

  # Run health check
  run_frankenphp_laravel_health_check
}

main
