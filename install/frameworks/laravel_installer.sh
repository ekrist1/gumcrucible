#!/usr/bin/env bash
# Laravel application installer and updater
# Handles new Laravel installations, repository cloning, and Composer dependencies
# Automatically configures Caddy and PHP-FPM for the Laravel application
set -euo pipefail

# Set component name for logging
export CRUCIBLE_COMPONENT="laravel_installer"

# Load progress library if present
PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"

if ! command -v gum >/dev/null 2>&1; then
  echo "[laravel-installer][warn] gum not found; proceeding without UI prompts" >&2
  gum() { shift || true; "$@"; }
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }
need_sudo() { if [[ $EUID -ne 0 ]]; then command_exists sudo && echo sudo; fi; }

# Default values
PROJECT_NAME=""
PROJECT_PATH=""
DOMAIN=""
EMAIL=""
REPOSITORY=""
BRANCH="main"
FORCE_INSTALL=false
UPDATE_EXISTING=false

show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install or update a Laravel application with automatic Caddy configuration

OPTIONS:
    -n, --name NAME         Project name (required for new installations)
    -p, --path PATH         Installation path (default: /var/www/NAME)
    -d, --domain DOMAIN     Domain name for Caddy (optional)
    -e, --email EMAIL       Email for Let's Encrypt (optional)
    -r, --repository URL    Git repository URL to clone
    -b, --branch BRANCH     Git branch to use (default: main)
    -f, --force             Force installation even if directory exists
    -u, --update            Update existing installation
    -h, --help              Show this help message

EXAMPLES:
    # Install new Laravel project
    $(basename "$0") --name myapp --domain example.com

    # Clone and install from repository
    $(basename "$0") --name myapp --repository https://github.com/user/laravel-app.git

    # Update existing installation
    $(basename "$0") --path /var/www/myapp --update

    # Install with custom configuration
    $(basename "$0") --name myapp --path /opt/laravel --domain app.example.com --email admin@example.com

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name)
      PROJECT_NAME="$2"
      shift 2
      ;;
    -p|--path)
      PROJECT_PATH="$2"
      shift 2
      ;;
    -d|--domain)
      DOMAIN="$2"
      shift 2
      ;;
    -e|--email)
      EMAIL="$2"
      shift 2
      ;;
    -r|--repository)
      REPOSITORY="$2"
      shift 2
      ;;
    -b|--branch)
      BRANCH="$2"
      shift 2
      ;;
    -f|--force)
      FORCE_INSTALL=true
      shift
      ;;
    -u|--update)
      UPDATE_EXISTING=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
  esac
done

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
  
  # Check for Caddy (optional but recommended)
  if ! command_exists caddy; then
    if declare -f log_warn >/dev/null 2>&1; then
      log_warn "Caddy not found - automatic web server configuration will be skipped"
    fi
  fi
  
  # Check for git if repository is specified
  if [[ -n "$REPOSITORY" ]] && ! command_exists git; then
    missing_deps+=("Git")
  fi
  
  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    echo "Missing required dependencies: ${missing_deps[*]}" >&2
    echo "Please install the missing dependencies first." >&2
    echo "Tip: Use the Core Services installer to install PHP and Composer" >&2
    exit 1
  fi
}

# Validate arguments
validate_arguments() {
  if [[ "$UPDATE_EXISTING" == "false" ]] && [[ -z "$PROJECT_NAME" ]] && [[ -z "$PROJECT_PATH" ]]; then
    echo "Error: Either --name or --path is required for new installations" >&2
    show_help
    exit 1
  fi
  
  # Set default project path if not specified
  if [[ -n "$PROJECT_NAME" ]] && [[ -z "$PROJECT_PATH" ]]; then
    PROJECT_PATH="/var/www/$PROJECT_NAME"
  fi
  
  # Validate project path
  if [[ -z "$PROJECT_PATH" ]]; then
    echo "Error: Project path could not be determined" >&2
    exit 1
  fi
  
  # Check if project already exists
  if [[ -d "$PROJECT_PATH" ]] && [[ "$UPDATE_EXISTING" == "false" ]] && [[ "$FORCE_INSTALL" == "false" ]]; then
    echo "Error: Directory $PROJECT_PATH already exists" >&2
    echo "Use --force to overwrite or --update to update existing installation" >&2
    exit 1
  fi
}

# Install new Laravel application
install_new_laravel() {
  if declare -f log_info >/dev/null 2>&1; then
    log_info "Installing new Laravel application"
    log_info "Project path: $PROJECT_PATH"
  fi
  
  local parent_dir
  parent_dir=$(dirname "$PROJECT_PATH")
  
  # Create parent directory if it doesn't exist
  if [[ ! -d "$parent_dir" ]]; then
    local sudo_cmd
    sudo_cmd=$(need_sudo || true)
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
  
  # Create parent directory if it doesn't exist
  if [[ ! -d "$parent_dir" ]]; then
    local sudo_cmd
    sudo_cmd=$(need_sudo || true)
    ${sudo_cmd:-} mkdir -p "$parent_dir"
  fi
  
  # Remove existing directory if force install
  if [[ "$FORCE_INSTALL" == "true" ]] && [[ -d "$PROJECT_PATH" ]]; then
    local sudo_cmd
    sudo_cmd=$(need_sudo || true)
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
  
  # Set ownership to caddy user if it exists
  if id caddy >/dev/null 2>&1; then
    ${sudo_cmd:-} chown -R caddy:caddy "$PROJECT_PATH" || true
  fi
  
  # Set proper permissions for Laravel
  ${sudo_cmd:-} chmod -R 755 "$PROJECT_PATH" || true
  ${sudo_cmd:-} chmod -R 775 "$PROJECT_PATH/storage" "$PROJECT_PATH/bootstrap/cache" || true
}

# Configure Caddy for Laravel
configure_caddy() {
  local caddy_script
  caddy_script="$(dirname "${BASH_SOURCE[0]}")/caddy_laravel.sh"
  
  if [[ ! -f "$caddy_script" ]]; then
    if declare -f log_warn >/dev/null 2>&1; then
      log_warn "Caddy Laravel configuration script not found: $caddy_script"
    fi
    return 0
  fi
  
  if ! command_exists caddy; then
    if declare -f log_warn >/dev/null 2>&1; then
      log_warn "Caddy not installed - skipping web server configuration"
    fi
    return 0
  fi
  
  if declare -f log_info >/dev/null 2>&1; then
    log_info "Configuring Caddy for Laravel application"
  fi
  
  # Build arguments for caddy_laravel script
  local caddy_args=("--path" "$PROJECT_PATH")
  
  if [[ -n "$DOMAIN" ]]; then
    caddy_args+=("--domain" "$DOMAIN")
  fi
  
  if [[ -n "$EMAIL" ]]; then
    caddy_args+=("--email" "$EMAIL")
  fi
  
  # Execute caddy configuration script
  "$caddy_script" "${caddy_args[@]}"
}

# Run health checks
run_laravel_health_check() {
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
  )
  
  # Check if Laravel is properly configured
  if grep -q "APP_KEY=base64:" "$PROJECT_PATH/.env" 2>/dev/null; then
    checks+=("grep -q 'APP_KEY=base64:' '$PROJECT_PATH/.env'")
  fi
  
  # Check if we can run artisan commands
  checks+=("php '$PROJECT_PATH/artisan' --version >/dev/null 2>&1")
  
  health_check_summary "Laravel Application" "${checks[@]}"
}

# Main execution
main() {
  validate_requirements
  validate_arguments
  
  if declare -f log_info >/dev/null 2>&1; then
    log_info "Laravel installer starting"
    log_info "Project: ${PROJECT_NAME:-$(basename "$PROJECT_PATH")}"
    log_info "Path: $PROJECT_PATH"
    [[ -n "$DOMAIN" ]] && log_info "Domain: $DOMAIN"
    [[ -n "$REPOSITORY" ]] && log_info "Repository: $REPOSITORY"
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
  configure_caddy
  
  # Summary
  if command_exists gum; then
    gum style --foreground 82 --bold "Laravel installation complete!"
    gum style --faint "Project: ${PROJECT_NAME:-$(basename "$PROJECT_PATH")}"
    gum style --faint "Path: $PROJECT_PATH"
    [[ -n "$DOMAIN" ]] && gum style --faint "Domain: $DOMAIN"
    [[ -n "$REPOSITORY" ]] && gum style --faint "Repository: $REPOSITORY"
  else
    echo "[laravel-installer] Installation complete!"
    echo "  Project: ${PROJECT_NAME:-$(basename "$PROJECT_PATH")}"
    echo "  Path: $PROJECT_PATH"
    [[ -n "$DOMAIN" ]] && echo "  Domain: $DOMAIN"
  fi
  
  # Run health check
  run_laravel_health_check
}

main "$@"