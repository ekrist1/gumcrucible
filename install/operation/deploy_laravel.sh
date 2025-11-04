#!/usr/bin/env bash
# Laravel application deployment script
# Handles zero-downtime deployments with rollback support
# Works with Nginx, Caddy, and FrankenPHP web servers
set -euo pipefail

# Set component name for logging
export CRUCIBLE_COMPONENT="deploy_laravel"

PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"

if ! command -v gum >/dev/null 2>&1; then
  echo "[deploy][warn] gum not found; proceeding without fancy UI" >&2
  gum() { shift || true; "$@"; }
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }
need_sudo() { if [[ $EUID -ne 0 ]]; then command_exists sudo && echo sudo; fi; }

# Deployment configuration
PROJECT_PATH=""
REPOSITORY=""
BRANCH="main"
RUN_MIGRATIONS=false
RUN_SEEDERS=false
OPTIMIZE_AUTOLOADER=true
CLEAR_CACHE=true
RESTART_QUEUE=true
MAINTENANCE_MODE=true
BACKUP_BEFORE_DEPLOY=true
DEPLOYMENT_METHOD=""
WEB_SERVER_TYPE=""

# Paths
RELEASES_DIR=""
SHARED_DIR=""
CURRENT_LINK=""
STORAGE_DIR=""
ENV_FILE=""
BACKUP_DIR=""

# Detect web server type
detect_web_server() {
  if systemctl is-active --quiet frankenphp 2>/dev/null; then
    echo "frankenphp"
  elif systemctl is-active --quiet caddy 2>/dev/null; then
    echo "caddy"
  elif systemctl is-active --quiet nginx 2>/dev/null; then
    echo "nginx"
  else
    echo "unknown"
  fi
}

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

# Interactive deployment configuration
get_deployment_config() {
  clear || true
  gum style --foreground 45 --bold "Laravel Application Deployment"
  gum style --faint "Deploy Laravel applications with zero-downtime"
  echo

  # Detect web server
  WEB_SERVER_TYPE=$(detect_web_server)
  if [[ "$WEB_SERVER_TYPE" == "unknown" ]]; then
    gum style --foreground 214 --bold "Warning: No web server detected"
    gum style --faint "Make sure Nginx, Caddy, or FrankenPHP is installed and running"
    echo
  else
    gum style --foreground 82 "Detected web server: $WEB_SERVER_TYPE"
    echo
  fi

  # Deployment method
  DEPLOYMENT_METHOD=$(gum choose --header "Select deployment method" \
    "Deploy from Git repository" \
    "Deploy existing application (in-place)" \
    "Cancel") || exit 0

  case "$DEPLOYMENT_METHOD" in
    "Cancel") exit 0 ;;
    "Deploy from Git repository")
      # Get repository URL
      while [[ -z "$REPOSITORY" ]]; do
        REPOSITORY=$(gum input --placeholder "https://github.com/user/repository.git" --prompt "Repository URL: ") || exit 0
        if [[ -z "$REPOSITORY" ]]; then
          gum style --foreground 196 "Repository URL is required!"
          echo
        fi
      done

      # Get branch
      BRANCH=$(gum input --placeholder "main" --prompt "Branch: " --value "main") || exit 0
      if [[ -z "$BRANCH" ]]; then
        BRANCH="main"
      fi
      ;;
    "Deploy existing application (in-place)")
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
      ;;
  esac

  # Get project path for Git deployments
  if [[ "$DEPLOYMENT_METHOD" == "Deploy from Git repository"* ]]; then
    local default_path="/var/www/$(basename "$REPOSITORY" .git)"
    PROJECT_PATH=$(gum input --placeholder "$default_path" --prompt "Deployment path: " --value "$default_path") || exit 0
    if [[ -z "$PROJECT_PATH" ]]; then
      PROJECT_PATH="$default_path"
    fi
  fi

  # Validate project path
  if [[ -z "$PROJECT_PATH" ]]; then
    gum style --foreground 196 "Project path is required!"
    exit 1
  fi

  # Deployment options
  echo
  gum style --foreground 212 --bold "Deployment Options"

  if gum confirm "Run database migrations?"; then
    RUN_MIGRATIONS=true

    if gum confirm "Run database seeders? (Use with caution in production!)"; then
      RUN_SEEDERS=true
    fi
  fi

  if ! gum confirm "Enable maintenance mode during deployment?"; then
    MAINTENANCE_MODE=false
  fi

  if ! gum confirm "Restart queue workers after deployment?"; then
    RESTART_QUEUE=false
  fi

  if ! gum confirm "Clear and optimize caches?"; then
    CLEAR_CACHE=false
  fi

  if [[ -d "$PROJECT_PATH" ]] && ! gum confirm "Create backup before deployment?"; then
    BACKUP_BEFORE_DEPLOY=false
  fi

  # Summary
  echo
  gum style --foreground 82 --bold "Deployment Configuration:"
  [[ -n "$REPOSITORY" ]] && gum style --faint "Repository: $REPOSITORY"
  [[ -n "$BRANCH" ]] && gum style --faint "Branch: $BRANCH"
  gum style --faint "Path: $PROJECT_PATH"
  gum style --faint "Web Server: $WEB_SERVER_TYPE"
  [[ "$RUN_MIGRATIONS" == "true" ]] && gum style --faint "Migrations: Yes"
  [[ "$RUN_SEEDERS" == "true" ]] && gum style --faint "Seeders: Yes"
  [[ "$MAINTENANCE_MODE" == "true" ]] && gum style --faint "Maintenance Mode: Yes"
  [[ "$RESTART_QUEUE" == "true" ]] && gum style --faint "Restart Queues: Yes"
  [[ "$BACKUP_BEFORE_DEPLOY" == "true" ]] && gum style --faint "Backup: Yes"
  echo

  if ! gum confirm "Proceed with deployment?"; then
    gum style --foreground 214 "Deployment cancelled"
    exit 0
  fi
}

# Setup deployment directory structure
setup_deployment_structure() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  if [[ "$DEPLOYMENT_METHOD" == "Deploy from Git repository"* ]]; then
    # Use zero-downtime deployment structure
    RELEASES_DIR="$PROJECT_PATH/releases"
    SHARED_DIR="$PROJECT_PATH/shared"
    CURRENT_LINK="$PROJECT_PATH/current"
    STORAGE_DIR="$SHARED_DIR/storage"
    ENV_FILE="$SHARED_DIR/.env"
    BACKUP_DIR="$PROJECT_PATH/backups"

    # Create directory structure
    for dir in "$RELEASES_DIR" "$SHARED_DIR" "$STORAGE_DIR" "$BACKUP_DIR"; do
      if [[ ! -d "$dir" ]]; then
        ${sudo_cmd:-} mkdir -p "$dir"
      fi
    done

    # Create shared storage subdirectories
    for subdir in app framework/cache framework/sessions framework/views logs; do
      if [[ ! -d "$STORAGE_DIR/$subdir" ]]; then
        ${sudo_cmd:-} mkdir -p "$STORAGE_DIR/$subdir"
      fi
    done
  else
    # In-place deployment
    STORAGE_DIR="$PROJECT_PATH/storage"
    ENV_FILE="$PROJECT_PATH/.env"
    BACKUP_DIR="$PROJECT_PATH/.backups"

    ${sudo_cmd:-} mkdir -p "$BACKUP_DIR"
  fi
}

# Create backup
create_backup() {
  if [[ "$BACKUP_BEFORE_DEPLOY" != "true" ]]; then
    return 0
  fi

  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  local backup_name="backup-$(date +%Y%m%d-%H%M%S)"
  local backup_path="$BACKUP_DIR/$backup_name"

  if declare -f log_info >/dev/null 2>&1; then
    log_info "Creating backup: $backup_name"
  fi

  gum spin --spinner line --title "Creating backup" -- bash -c "
    set -euo pipefail
    ${sudo_cmd:-} mkdir -p '$backup_path'

    # Backup current release or application
    if [[ -L '$CURRENT_LINK' ]]; then
      ${sudo_cmd:-} cp -a \$(readlink -f '$CURRENT_LINK') '$backup_path/release'
    elif [[ -d '$PROJECT_PATH' ]]; then
      ${sudo_cmd:-} rsync -a --exclude='.git' --exclude='node_modules' --exclude='vendor' '$PROJECT_PATH/' '$backup_path/release/'
    fi

    # Backup .env file
    if [[ -f '$ENV_FILE' ]]; then
      ${sudo_cmd:-} cp '$ENV_FILE' '$backup_path/.env'
    fi

    # Backup database (if MySQL is available)
    if command -v mysqldump >/dev/null 2>&1 && [[ -f '$ENV_FILE' ]]; then
      local db_name=\$(grep '^DB_DATABASE=' '$ENV_FILE' 2>/dev/null | cut -d'=' -f2 || echo '')
      local db_user=\$(grep '^DB_USERNAME=' '$ENV_FILE' 2>/dev/null | cut -d'=' -f2 || echo '')
      local db_pass=\$(grep '^DB_PASSWORD=' '$ENV_FILE' 2>/dev/null | cut -d'=' -f2 || echo '')

      if [[ -n \"\$db_name\" ]] && [[ -n \"\$db_user\" ]]; then
        MYSQL_PWD=\"\$db_pass\" mysqldump -u\"\$db_user\" \"\$db_name\" > '$backup_path/database.sql' 2>/dev/null || true
      fi
    fi
  "

  # Keep only last 5 backups
  ${sudo_cmd:-} bash -c "cd '$BACKUP_DIR' && ls -t | tail -n +6 | xargs -r rm -rf" || true

  gum style --foreground 82 "Backup created: $backup_name"
}

# Clone or pull repository
deploy_from_git() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)
  local release_name="release-$(date +%Y%m%d-%H%M%S)"
  local release_path="$RELEASES_DIR/$release_name"

  if declare -f log_info >/dev/null 2>&1; then
    log_info "Deploying from Git: $REPOSITORY (branch: $BRANCH)"
    log_info "Release: $release_name"
  fi

  # Clone repository
  gum spin --spinner line --title "Cloning repository" -- \
    git clone --branch "$BRANCH" --depth 1 "$REPOSITORY" "$release_path"

  # Link shared directories
  gum spin --spinner line --title "Setting up shared directories" -- bash -c "
    set -euo pipefail
    # Remove storage directory and link to shared
    ${sudo_cmd:-} rm -rf '$release_path/storage'
    ${sudo_cmd:-} ln -sf '$STORAGE_DIR' '$release_path/storage'

    # Link .env file
    if [[ -f '$ENV_FILE' ]]; then
      ${sudo_cmd:-} ln -sf '$ENV_FILE' '$release_path/.env'
    else
      # Copy from example if .env doesn't exist
      if [[ -f '$release_path/.env.example' ]]; then
        ${sudo_cmd:-} cp '$release_path/.env.example' '$ENV_FILE'
        ${sudo_cmd:-} ln -sf '$ENV_FILE' '$release_path/.env'
      fi
    fi
  "

  echo "$release_path"
}

# Deploy in-place (existing application)
deploy_in_place() {
  if declare -f log_info >/dev/null 2>&1; then
    log_info "Deploying in-place: $PROJECT_PATH"
  fi

  # If it's a git repository, pull latest changes
  if [[ -d "$PROJECT_PATH/.git" ]]; then
    cd "$PROJECT_PATH"

    # Detect current branch if not specified
    if [[ -z "$BRANCH" ]]; then
      BRANCH=$(git rev-parse --abbrev-ref HEAD)
    fi

    gum spin --spinner line --title "Pulling latest changes from Git" -- \
      git pull origin "$BRANCH"
  fi

  echo "$PROJECT_PATH"
}

# Install Composer dependencies
install_dependencies() {
  local app_path="$1"

  if [[ ! -f "$app_path/composer.json" ]]; then
    if declare -f log_warn >/dev/null 2>&1; then
      log_warn "No composer.json found, skipping dependency installation"
    fi
    return 0
  fi

  cd "$app_path"

  if declare -f log_info >/dev/null 2>&1; then
    log_info "Installing Composer dependencies"
  fi

  gum spin --spinner line --title "Installing Composer dependencies" -- \
    composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader
}

# Generate application key if needed
generate_app_key() {
  local app_path="$1"

  if [[ ! -f "$app_path/.env" ]]; then
    if declare -f log_warn >/dev/null 2>&1; then
      log_warn "No .env file found, skipping key generation"
    fi
    return 0
  fi

  cd "$app_path"

  # Check if APP_KEY is set
  if ! grep -q "APP_KEY=base64:" "$app_path/.env" 2>/dev/null; then
    if declare -f log_info >/dev/null 2>&1; then
      log_info "Generating application key"
    fi

    gum spin --spinner line --title "Generating application key" -- \
      php artisan key:generate --no-interaction
  fi
}

# Run database migrations
run_migrations() {
  local app_path="$1"

  if [[ "$RUN_MIGRATIONS" != "true" ]]; then
    return 0
  fi

  cd "$app_path"

  if declare -f log_info >/dev/null 2>&1; then
    log_info "Running database migrations"
  fi

  gum spin --spinner line --title "Running database migrations" -- \
    php artisan migrate --force --no-interaction

  # Run seeders if requested
  if [[ "$RUN_SEEDERS" == "true" ]]; then
    if declare -f log_info >/dev/null 2>&1; then
      log_info "Running database seeders"
    fi

    gum spin --spinner line --title "Running database seeders" -- \
      php artisan db:seed --force --no-interaction
  fi
}

# Clear and optimize caches
optimize_application() {
  local app_path="$1"

  if [[ "$CLEAR_CACHE" != "true" ]]; then
    return 0
  fi

  cd "$app_path"

  if declare -f log_info >/dev/null 2>&1; then
    log_info "Optimizing application"
  fi

  gum spin --spinner line --title "Clearing caches" -- bash -c "
    set -euo pipefail
    php artisan cache:clear --no-interaction
    php artisan config:clear --no-interaction
    php artisan route:clear --no-interaction
    php artisan view:clear --no-interaction
  "

  gum spin --spinner line --title "Optimizing application" -- bash -c "
    set -euo pipefail
    php artisan config:cache --no-interaction
    php artisan route:cache --no-interaction
    php artisan view:cache --no-interaction
  "
}

# Set proper permissions
set_permissions() {
  local app_path="$1"
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  if declare -f log_info >/dev/null 2>&1; then
    log_info "Setting file permissions"
  fi

  # Determine web user based on web server
  local web_user="www-data"
  case "$WEB_SERVER_TYPE" in
    frankenphp)
      web_user="frankenphp"
      ;;
    caddy)
      if id caddy >/dev/null 2>&1; then
        web_user="caddy"
      fi
      ;;
    nginx)
      if id nginx >/dev/null 2>&1; then
        web_user="nginx"
      fi
      ;;
  esac

  gum spin --spinner line --title "Setting permissions" -- bash -c "
    set -euo pipefail
    ${sudo_cmd:-} chown -R $web_user:$web_user '$app_path' || true
    ${sudo_cmd:-} chmod -R 755 '$app_path' || true
    ${sudo_cmd:-} chmod -R 775 '$app_path/storage' '$app_path/bootstrap/cache' || true
  "
}

# Switch to new release (zero-downtime)
switch_release() {
  local new_release="$1"
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  if [[ -z "$CURRENT_LINK" ]]; then
    return 0
  fi

  if declare -f log_info >/dev/null 2>&1; then
    log_info "Switching to new release"
  fi

  gum spin --spinner line --title "Activating new release" -- bash -c "
    set -euo pipefail
    ${sudo_cmd:-} ln -sfn '$new_release' '$CURRENT_LINK.tmp'
    ${sudo_cmd:-} mv -Tf '$CURRENT_LINK.tmp' '$CURRENT_LINK'
  "

  # Clean up old releases (keep last 3)
  ${sudo_cmd:-} bash -c "cd '$RELEASES_DIR' && ls -t | tail -n +4 | xargs -r rm -rf" || true
}

# Restart services
restart_services() {
  local sudo_cmd
  sudo_cmd=$(need_sudo || true)

  # Restart queue workers
  if [[ "$RESTART_QUEUE" == "true" ]]; then
    if command_exists supervisorctl; then
      if declare -f log_info >/dev/null 2>&1; then
        log_info "Restarting Supervisor queue workers"
      fi

      gum spin --spinner line --title "Restarting queue workers" -- \
        bash -c "${sudo_cmd:-} supervisorctl restart all >/dev/null 2>&1 || true"
    fi
  fi

  # Reload web server if needed
  case "$WEB_SERVER_TYPE" in
    frankenphp)
      if declare -f log_info >/dev/null 2>&1; then
        log_info "Reloading FrankenPHP"
      fi
      gum spin --spinner line --title "Reloading FrankenPHP" -- \
        bash -c "${sudo_cmd:-} systemctl reload frankenphp >/dev/null 2>&1 || true"
      ;;
    caddy)
      if declare -f log_info >/dev/null 2>&1; then
        log_info "Reloading Caddy"
      fi
      gum spin --spinner line --title "Reloading Caddy" -- \
        bash -c "${sudo_cmd:-} caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true"
      ;;
    nginx)
      if declare -f log_info >/dev/null 2>&1; then
        log_info "Reloading Nginx"
      fi
      gum spin --spinner line --title "Reloading Nginx" -- \
        bash -c "${sudo_cmd:-} systemctl reload nginx >/dev/null 2>&1 || true"
      ;;
  esac
}

# Enable/disable maintenance mode
maintenance_mode() {
  local app_path="$1"
  local action="$2"  # up or down

  if [[ "$MAINTENANCE_MODE" != "true" ]]; then
    return 0
  fi

  cd "$app_path"

  if [[ "$action" == "down" ]]; then
    if declare -f log_info >/dev/null 2>&1; then
      log_info "Enabling maintenance mode"
    fi
    gum spin --spinner line --title "Enabling maintenance mode" -- \
      php artisan down --retry=60 --no-interaction || true
  else
    if declare -f log_info >/dev/null 2>&1; then
      log_info "Disabling maintenance mode"
    fi
    gum spin --spinner line --title "Disabling maintenance mode" -- \
      php artisan up --no-interaction || true
  fi
}

# Main deployment flow
main() {
  get_deployment_config
  setup_deployment_structure
  create_backup

  local deploy_path

  # Enable maintenance mode
  if [[ -d "$PROJECT_PATH" ]] || [[ -L "$CURRENT_LINK" ]]; then
    local current_path="$PROJECT_PATH"
    if [[ -L "$CURRENT_LINK" ]]; then
      current_path=$(readlink -f "$CURRENT_LINK")
    fi
    maintenance_mode "$current_path" "down"
  fi

  # Deploy based on method
  case "$DEPLOYMENT_METHOD" in
    "Deploy from Git repository")
      deploy_path=$(deploy_from_git)
      ;;
    "Deploy existing application (in-place)")
      deploy_path=$(deploy_in_place)
      ;;
  esac

  # Run deployment steps
  install_dependencies "$deploy_path"
  generate_app_key "$deploy_path"
  run_migrations "$deploy_path"
  optimize_application "$deploy_path"
  set_permissions "$deploy_path"

  # Switch to new release (for Git deployments)
  if [[ "$DEPLOYMENT_METHOD" == "Deploy from Git repository"* ]]; then
    switch_release "$deploy_path"
  fi

  # Restart services
  restart_services

  # Disable maintenance mode
  maintenance_mode "$deploy_path" "up"

  # Success message
  echo
  gum style --foreground 82 --bold "✨ Deployment completed successfully!"
  echo
  gum style --faint "Application path: $PROJECT_PATH"
  [[ -n "$REPOSITORY" ]] && gum style --faint "Repository: $REPOSITORY"
  [[ -n "$BRANCH" ]] && gum style --faint "Branch: $BRANCH"
  gum style --faint "Web server: $WEB_SERVER_TYPE"

  if [[ "$BACKUP_BEFORE_DEPLOY" == "true" ]]; then
    echo
    gum style --foreground 212 --bold "💾 Backup Information:"
    gum style --faint "Backups are stored in: $BACKUP_DIR"
    gum style --faint "To rollback, restore files from the latest backup"
  fi

  if [[ "$DEPLOYMENT_METHOD" == "Deploy from Git repository"* ]]; then
    echo
    gum style --foreground 212 --bold "📦 Release Management:"
    gum style --faint "Current release: $(readlink -f "$CURRENT_LINK" 2>/dev/null | xargs basename)"
    gum style --faint "Releases directory: $RELEASES_DIR"
    gum style --faint "Keeping last 3 releases for rollback"
  fi

  echo
  gum style --foreground 82 "🚀 Your Laravel application is live!"
}

main "$@"
