#!/usr/bin/env bash
# Configure Caddy + PHP-FPM for Laravel application
# Invokable script that configures Caddy without user input
# Creates dedicated PHP-FPM pool and updates Caddyfile with Laravel-optimized configuration
# Based on modern Caddy v2 best practices for Laravel applications
set -euo pipefail

# Set component name for logging
export CRUCIBLE_COMPONENT="caddy_laravel"

if ! command -v gum >/dev/null 2>&1; then
  echo "[caddy-laravel][warn] gum not found; proceeding without UI prompts" >&2
  gum() { shift || true; "$@"; }
fi

# Load progress bar if present
PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"

command_exists() { command -v "$1" >/dev/null 2>&1; }
need_sudo() { if [[ $EUID -ne 0 ]]; then command_exists sudo && echo sudo; fi; }
run() { local pre=$(need_sudo); echo "> ${pre:+$pre }$*"; ${pre:-} "$@"; }

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  DIST_ID="${ID,,}"; DIST_LIKE="${ID_LIKE:-}"; DIST_LIKE="${DIST_LIKE,,}"
else
  echo "[caddy-laravel][error] Cannot detect OS" >&2; exit 1
fi

# Detect PHP major.minor (prefer 8.4 else highest)
php_version=""
for v in 8.4 8.3 8.2; do
  if [[ -d /etc/php/$v/fpm ]]; then php_version="$v"; break; fi
  if command_exists php; then
    cur=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    [[ "$cur" == "$v" ]] && php_version="$v"
  fi
done
[[ -z "$php_version" && -d /etc/php ]] && php_version=$(ls /etc/php | sort -r | head -n1 || true)

# Paths differ per distro
if [[ -n "$php_version" && -d /etc/php/$php_version/fpm/pool.d ]]; then
  POOL_DIR="/etc/php/$php_version/fpm/pool.d"
  SERVICE_FPM="php${php_version}-fpm"
  SOCKET_DIR="/run/php-fpm"
  POOL_FILE="$POOL_DIR/caddy.conf"
else
  # Fedora / RHEL style
  POOL_DIR="/etc/php-fpm.d"
  SERVICE_FPM="php-fpm"
  SOCKET_DIR="/run/php-fpm"
  POOL_FILE="$POOL_DIR/caddy.conf"
fi

CADDYFILE="/etc/caddy/Caddyfile"
BACKUP_SUFFIX=".bak.$(date +%Y%m%d%H%M%S)"

# Parse command line arguments
DOMAIN=""
PROJECT_PATH="/var/www/laravel"
EMAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain|-d)
      DOMAIN="$2"
      shift 2
      ;;
    --path|-p)
      PROJECT_PATH="$2"
      shift 2
      ;;
    --email|-e)
      EMAIL="$2"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Configure Caddy + PHP-FPM for Laravel application

OPTIONS:
    -d, --domain DOMAIN     Domain name (optional, defaults to :80)
    -p, --path PATH         Laravel project path (default: /var/www/laravel)
    -e, --email EMAIL       ACME email for Let's Encrypt (optional)
    -h, --help              Show this help message

EXAMPLES:
    $(basename "$0")                                    # Default setup on :80
    $(basename "$0") -d example.com -p /var/www/myapp   # Custom domain and path
    $(basename "$0") --domain example.com --email admin@example.com

EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

PUBLIC_DIR="$PROJECT_PATH/public"

# Log configuration being applied
if declare -f log_info >/dev/null 2>&1; then
  log_info "Configuring Caddy for Laravel application"
  log_info "Domain: ${DOMAIN:-:80}"
  log_info "Project path: $PROJECT_PATH"
  log_info "Public directory: $PUBLIC_DIR"
fi

# Create project/public if absent
if [[ ! -d "$PUBLIC_DIR" ]]; then
  run mkdir -p "$PUBLIC_DIR"
  # Add a placeholder index if missing
  if [[ ! -f "$PUBLIC_DIR/index.php" ]]; then
    cat <<'PHP' | run tee "$PUBLIC_DIR/index.php" >/dev/null
<?php echo "Laravel placeholder (install app)"; 
PHP
  fi
fi

# Ensure caddy user owns tree (best effort)
if id caddy >/dev/null 2>&1; then
  run chown -R caddy:caddy "$PROJECT_PATH" || true
fi

# Prepare socket directory
run mkdir -p "$SOCKET_DIR"
if id caddy >/dev/null 2>&1; then
  run chown caddy:caddy "$SOCKET_DIR" || true
fi

# Install tmpfiles entry for persistence across reboots
TMPFILES_CONF="/etc/tmpfiles.d/caddy-php-fpm.conf"
if [[ ! -f $TMPFILES_CONF ]]; then
  echo "d $SOCKET_DIR 0755 caddy caddy -" | run tee "$TMPFILES_CONF" >/dev/null || true
fi

# Create / update PHP-FPM pool configuration (idempotent)
POOL_CONTENT="[caddy]
user = caddy
group = caddy
listen = ${SOCKET_DIR}/caddy.sock
listen.owner = caddy
listen.group = caddy
listen.mode = 0660
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
php_admin_value[error_log] = /var/log/php-fpm/caddy-error.log
php_admin_flag[log_errors] = on
"

# Check if pool configuration needs updating (idempotent)
pool_needs_update=false
if [[ ! -f "$POOL_FILE" ]]; then
  pool_needs_update=true
  if declare -f log_info >/dev/null 2>&1; then
    log_info "Creating new PHP-FPM pool configuration: $POOL_FILE"
  fi
elif ! diff -q <(echo "$POOL_CONTENT") "$POOL_FILE" >/dev/null 2>&1; then
  pool_needs_update=true
  if declare -f log_info >/dev/null 2>&1; then
    log_info "PHP-FPM pool configuration needs updating: $POOL_FILE"
  fi
  # Backup existing file
  if declare -f backup_file >/dev/null 2>&1; then
    backup_file "$POOL_FILE"
  else
    run cp "$POOL_FILE" "${POOL_FILE}${BACKUP_SUFFIX}" || true
  fi
else
  if declare -f log_info >/dev/null 2>&1; then
    log_info "PHP-FPM pool configuration already correct: $POOL_FILE"
  fi
fi

if [[ "$pool_needs_update" == "true" ]]; then
  printf "%s" "$POOL_CONTENT" | run tee "$POOL_FILE" >/dev/null
fi

# Build modern Laravel Caddyfile configuration based on best practices
PHP_SOCK="unix//${SOCKET_DIR}/caddy.sock"

if [[ -n "$DOMAIN" ]]; then
  SITE_LABEL="$DOMAIN"
else
  SITE_LABEL=":80"
fi

# Modern Laravel Caddy v2 configuration with optimizations
SITE_BLOCK="$SITE_LABEL {
    root * ${PUBLIC_DIR}
    
    # Compression with modern algorithms
    encode zstd gzip
    
    # PHP-FPM integration for Laravel
    php_fastcgi ${PHP_SOCK}
    
    # Static file serving
    file_server
    
    # Security headers
    header {
        X-Frame-Options DENY
        X-Content-Type-Options nosniff
        Referrer-Policy strict-origin-when-cross-origin
        X-Powered-By \"Crucible Laravel\"
    }
    
    # Handle Laravel's index.php routing
    try_files {path} {path}/ /index.php?{query}
}
"

# Global configuration block
if [[ -n "$EMAIL" ]]; then
  GLOBAL_BLOCK="{
    email ${EMAIL}
}

"
else
  GLOBAL_BLOCK=""
fi

# Update Caddyfile configuration (idempotent)
caddy_needs_update=false
site_marker="# Crucible Laravel Site: ${SITE_LABEL//[^a-zA-Z0-9._-]/_}"

# Check if Caddyfile needs updating
if [[ ! -f "$CADDYFILE" ]]; then
  caddy_needs_update=true
  if declare -f log_info >/dev/null 2>&1; then
    log_info "Creating new Caddyfile: $CADDYFILE"
  fi
elif ! grep -q "$site_marker" "$CADDYFILE"; then
  caddy_needs_update=true
  if declare -f log_info >/dev/null 2>&1; then
    log_info "Adding Laravel site configuration to Caddyfile"
  fi
else
  # Check if existing configuration matches
  if grep -A 20 "$site_marker" "$CADDYFILE" | grep -q "root \* $PUBLIC_DIR"; then
    if declare -f log_info >/dev/null 2>&1; then
      log_info "Caddyfile configuration already correct for site: $SITE_LABEL"
    fi
  else
    caddy_needs_update=true
    if declare -f log_info >/dev/null 2>&1; then
      log_info "Updating existing Laravel site configuration in Caddyfile"
    fi
  fi
fi

if [[ "$caddy_needs_update" == "true" ]]; then
  # Backup existing Caddyfile
  if [[ -f "$CADDYFILE" ]]; then
    if declare -f backup_file >/dev/null 2>&1; then
      backup_file "$CADDYFILE"
    else
      run cp "$CADDYFILE" "${CADDYFILE}${BACKUP_SUFFIX}" || true
    fi
  fi
  
  # Create or update Caddyfile
  if [[ -f "$CADDYFILE" ]] && grep -q "$site_marker" "$CADDYFILE"; then
    # Update existing site configuration
    temp_file=$(mktemp)
    awk -v marker="$site_marker" -v block="$SITE_BLOCK" '
      BEGIN { in_block = 0; printed = 0 }
      $0 ~ marker { 
        print $0
        print block
        printed = 1
        in_block = 1
        next
      }
      in_block && $0 ~ /^}/ {
        in_block = 0
        next
      }
      !in_block { print }
    ' "$CADDYFILE" > "$temp_file"
    run mv "$temp_file" "$CADDYFILE"
  else
    # Append new site configuration
    {
      [[ -n "$GLOBAL_BLOCK" ]] && printf "%s" "$GLOBAL_BLOCK"
      echo "$site_marker"
      printf "%s\n" "$SITE_BLOCK"
    } | run tee -a "$CADDYFILE" >/dev/null
  fi
fi

# Reload services if configurations were updated
if [[ "$pool_needs_update" == "true" ]] || [[ "$caddy_needs_update" == "true" ]]; then
  if systemctl list-unit-files | grep -q "$SERVICE_FPM"; then
    if declare -f log_info >/dev/null 2>&1; then
      log_info "Restarting PHP-FPM service: $SERVICE_FPM"
    fi
    run systemctl restart "$SERVICE_FPM" || true
  fi
  
  if declare -f log_info >/dev/null 2>&1; then
    log_info "Reloading Caddy configuration"
  fi
  run systemctl reload caddy 2>/dev/null || run systemctl restart caddy || true
else
  if declare -f log_info >/dev/null 2>&1; then
    log_info "No service restart needed - configurations unchanged"
  fi
fi

# Summary output
if command_exists gum; then
  gum style --foreground 82 --bold "Caddy Laravel configuration complete"
  gum style --faint "Domain: ${DOMAIN:-:80}"
  gum style --faint "Project root: $PROJECT_PATH"
  gum style --faint "Public directory: $PUBLIC_DIR" 
  gum style --faint "PHP-FPM pool: $(basename "$POOL_FILE")"
  gum style --faint "Socket: $PHP_SOCK"
else
  echo "[caddy-laravel] Configuration complete"
  echo "  Domain: ${DOMAIN:-:80}"
  echo "  Project root: $PROJECT_PATH"
  echo "  Public directory: $PUBLIC_DIR"
  echo "  PHP-FPM pool: $(basename "$POOL_FILE")"
fi

run_caddy_laravel_health_check() {
  if ! declare -f health_check_summary >/dev/null 2>&1; then
    if declare -f log_warn >/dev/null 2>&1; then
      log_warn "Health check functions not available, skipping validation"
    fi
    return 0
  fi
  
  local checks=(
    "validate_service_enabled caddy"
    "validate_service_running caddy"
    "validate_service_enabled $SERVICE_FPM"
    "validate_service_running $SERVICE_FPM"
    "test -f '$CADDYFILE'"
    "test -f '$POOL_FILE'"
    "test -S '$SOCKET_DIR/caddy.sock'"
    "test -d '$PUBLIC_DIR'"
  )
  
  # Check if Caddy configuration is valid
  if command_exists caddy; then
    checks+=("caddy validate --config '$CADDYFILE' >/dev/null 2>&1")
  fi
  
  health_check_summary "Caddy Laravel Configuration" "${checks[@]}"
}

# Run health check if available
if declare -f health_check_summary >/dev/null 2>&1; then
  run_caddy_laravel_health_check
fi
