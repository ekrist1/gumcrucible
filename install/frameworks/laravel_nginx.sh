#!/usr/bin/env bash
# Laravel application installer with Nginx configuration
# Creates new Laravel applications or clones repositories with full Nginx setup
# Automatically detects PHP-FPM version and configures secure Nginx virtual host
set -euo pipefail

# Set component name for logging
export CRUCIBLE_COMPONENT="laravel_nginx"

# Load progress library if present
PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"

if ! command -v gum >/dev/null 2>&1; then
  echo "[laravel-nginx][warn] gum not found; proceeding without UI prompts" >&2
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

# Interactive user input using gum
get_user_input() {
  clear || true
  gum style --foreground 45 --bold "Laravel + Nginx Application Setup"
  gum style --faint "This will create a new Laravel application with Nginx configuration"
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
  echo
  
  if ! gum confirm "Proceed with installation?"; then
    gum style --foreground 214 "Installation cancelled"
    exit 0
  fi
}

# Check if Nginx is installed
check_nginx_installed() {
  if ! command_exists nginx; then
    gum style --foreground 196 --bold "ERROR: Nginx is not installed!"
    gum style --faint "Please install Nginx first using:"
    gum style --faint "  ./install/services/nginx.sh"
    gum style --faint "Or through the Core Services menu"
    exit 1
  fi
  
  # Check if Nginx is running
  if ! systemctl is-active --quiet nginx 2>/dev/null; then
    if declare -f log_warn >/dev/null 2>&1; then
      log_warn "Nginx is installed but not running. Attempting to start..."
    fi
    local sudo_cmd
    sudo_cmd=$(need_sudo || true)
    ${sudo_cmd:-} systemctl start nginx || {
      gum style --foreground 196 "Failed to start Nginx service"
      exit 1
    }
  fi
}

# Detect PHP-FPM version and socket path
detect_php_fpm() {
  local php_version=""
  local socket_path=""
  
  # Try to detect PHP version
  if command_exists php; then
    php_version=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "")
  fi
  
  # Common PHP-FPM socket locations
  local possible_sockets=(
    "/var/run/php/php${php_version}-fpm.sock"
    "/run/php-fpm/www.sock"
    "/var/run/php-fpm/www.sock"
    "/run/php/php${php_version}-fpm.sock"
    "/var/run/php/php8.4-fpm.sock"
    "/var/run/php/php8.3-fpm.sock" 
    "/var/run/php/php8.2-fpm.sock"
    "/var/run/php/php8.1-fpm.sock"
  )
  
  # Find the first existing socket
  for sock in "${possible_sockets[@]}"; do
    if [[ -S "$sock" ]]; then
      socket_path="$sock"
      break
    fi
  done
  
  # If no socket found, try to detect from systemd
  if [[ -z "$socket_path" ]] && command_exists systemctl; then
    local fpm_services
    fpm_services=$(systemctl list-unit-files --type=service | grep -E 'php.*fpm' | head -1 | awk '{print $1}' || echo "")
    if [[ -n "$fpm_services" ]]; then
      # Extract version from service name
      local version
      version=$(echo "$fpm_services" | grep -oE '[0-9]+\.[0-9]+' || echo "")
      if [[ -n "$version" ]]; then
        socket_path="/var/run/php/php${version}-fpm.sock"
      fi
    fi
  fi
  
  if [[ -z "$socket_path" ]]; then
    gum style --foreground 196 --bold "ERROR: Cannot detect PHP-FPM socket!"
    gum style --faint "Please ensure PHP-FPM is installed and running:"
    gum style --faint "  ./install/services/php84.sh"
    exit 1
  fi
  
  echo "$socket_path"
}

# Validate requirements
validate_requirements() {
  local missing_deps=()
  
  # Check for PHP
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
  
  # Validate repository URL for cloning
  if [[ -n "$REPOSITORY" ]] && [[ -z "$PROJECT_NAME" ]]; then
    # For repository cloning, we don't need PROJECT_NAME
    true
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

# Check if Nginx configuration already exists
is_nginx_configured() {
  local config_file="/etc/nginx/conf.d/${DOMAIN}.conf"
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
  
  # Set ownership to www-data (or nginx user if it exists)
  local web_user="www-data"
  if id nginx >/dev/null 2>&1; then
    web_user="nginx"
  fi
  
  if id "$web_user" >/dev/null 2>&1; then
    ${sudo_cmd:-} chown -R "$web_user:$web_user" "$PROJECT_PATH" || true
  fi
  
  # Set proper permissions for Laravel
  ${sudo_cmd:-} chmod -R 755 "$PROJECT_PATH" || true
  ${sudo_cmd:-} chmod -R 775 "$PROJECT_PATH/storage" "$PROJECT_PATH/bootstrap/cache" || true
}

# Create Nginx configuration
create_nginx_config() {
  local config_file="/etc/nginx/conf.d/${DOMAIN}.conf"
  local socket_path
  socket_path=$(detect_php_fpm)
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  
  if declare -f log_info >/dev/null 2>&1; then
    log_info "Creating Nginx configuration: $config_file"
    log_info "PHP-FPM socket: $socket_path"
  fi
  
  # Check if configuration already exists and is correct (idempotent)
  if is_nginx_configured; then
    if declare -f log_info >/dev/null 2>&1; then
      log_info "Nginx configuration already exists and is correct"
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
  
  # Create Nginx configuration
  cat <<EOF | ${sudo_cmd:-} tee "$config_file" >/dev/null
server {
    listen 80;
    server_name $DOMAIN;
    root $PROJECT_PATH/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";

    index index.html index.htm index.php;

    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php\$ {
        fastcgi_pass unix:$socket_path;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
  
  # Test Nginx configuration
  if ! ${sudo_cmd:-} nginx -t >/dev/null 2>&1; then
    gum style --foreground 196 "Error: Invalid Nginx configuration"
    ${sudo_cmd:-} nginx -t
    exit 1
  fi
  
  # Reload Nginx
  gum spin --spinner line --title "Reloading Nginx configuration" -- \
    bash -c "${sudo_cmd:-} systemctl reload nginx"
}

# Run health checks
run_laravel_nginx_health_check() {
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
    "test -f '/etc/nginx/conf.d/${DOMAIN}.conf'"
    "nginx -t >/dev/null 2>&1"
    "systemctl is-active --quiet nginx"
  )
  
  # Check if Laravel is properly configured
  if grep -q "APP_KEY=base64:" "$PROJECT_PATH/.env" 2>/dev/null; then
    checks+=("grep -q 'APP_KEY=base64:' '$PROJECT_PATH/.env'")
  fi
  
  # Check if we can run artisan commands
  checks+=("php '$PROJECT_PATH/artisan' --version >/dev/null 2>&1")
  
  health_check_summary "Laravel + Nginx" "${checks[@]}"
}

# Main execution
main() {
  check_nginx_installed
  validate_requirements
  get_user_input
  validate_arguments
  
  if declare -f log_info >/dev/null 2>&1; then
    log_info "Laravel Nginx installer starting"
    log_info "Domain: $DOMAIN"
    log_info "Project path: $PROJECT_PATH"
    [[ -n "$REPOSITORY" ]] && log_info "Repository: $REPOSITORY"
  fi
  
  # Check if already configured
  if is_laravel_configured && is_nginx_configured && [[ "$FORCE_INSTALL" == "false" ]] && [[ "$UPDATE_EXISTING" == "false" ]]; then
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
  create_nginx_config
  
  # Summary and important notice
  gum style --foreground 82 --bold "Laravel + Nginx installation complete!"
  echo
  gum style --foreground 212 --bold "🌐 IMPORTANT: DNS Configuration Required!"
  gum style --foreground 214 "Please ensure your domain points to this server:"
  echo
  gum style --faint "1. Update your DNS records:"
  gum style --faint "   $DOMAIN → $(curl -s ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")"
  echo
  gum style --faint "2. Wait for DNS propagation (may take up to 24 hours)"
  echo
  gum style --faint "3. Optional: Set up SSL certificate:"
  gum style --faint "   sudo certbot --nginx -d $DOMAIN"
  echo
  gum style --faint "Application Details:"
  gum style --faint "• Domain: $DOMAIN"
  gum style --faint "• Path: $PROJECT_PATH"
  gum style --faint "• Config: /etc/nginx/conf.d/${DOMAIN}.conf"
  gum style --faint "• Public URL: http://$DOMAIN"
  
  # Run health check
  run_laravel_nginx_health_check
}

main