#!/usr/bin/env bash
# Prepare Caddy + PHP-FPM socket configuration for a Laravel site.
# Creates a dedicated PHP-FPM pool (caddy) with a unix socket and updates Caddyfile.
# Prompts for domain and project path. Idempotent and will backup existing configs.
set -euo pipefail

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

# Gather inputs
project_path_default="/var/www/laravel"
if command_exists gum; then
  gum style --foreground 45 --bold "Configure Laravel site for Caddy"
  DOMAIN=$(gum input --placeholder "Domain (blank for :80)" --value "" || echo "")
  PROJECT_PATH=$(gum input --placeholder "Laravel project path" --value "$project_path_default" || echo "$project_path_default")
  EMAIL=$(gum input --placeholder "ACME email (optional)" --value "" || echo "")
else
  DOMAIN=""; PROJECT_PATH="$project_path_default"; EMAIL=""
fi

[[ -z "$PROJECT_PATH" ]] && PROJECT_PATH="$project_path_default"
PUBLIC_DIR="$PROJECT_PATH/public"

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

# Create / update PHP-FPM pool configuration
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

if [[ -f "$POOL_FILE" ]]; then
  OVERWRITE=yes
  if command_exists gum; then
    gum confirm "Overwrite existing pool $(basename "$POOL_FILE")?" || OVERWRITE=no
  fi
  if [[ $OVERWRITE == yes ]]; then
    run cp "$POOL_FILE" "${POOL_FILE}${BACKUP_SUFFIX}" || true
    printf "%s" "$POOL_CONTENT" | run tee "$POOL_FILE" >/dev/null
  fi
else
  printf "%s" "$POOL_CONTENT" | run tee "$POOL_FILE" >/dev/null
fi

# Build Caddyfile block
SITE_BLOCK=""
PHP_SOCK="unix//${SOCKET_DIR}/caddy.sock"
ROOT_DIRECTIVE="root * ${PUBLIC_DIR}"
FASTCGI_DIRECTIVE="php_fastcgi ${PHP_SOCK}"
EXTRA_HEADER="header X-Powered-By \"Crucible\""

if [[ -n "$DOMAIN" ]]; then
  SITE_LABEL="$DOMAIN"
else
  SITE_LABEL=":80"
fi

SITE_BLOCK+="$SITE_LABEL {\n"
SITE_BLOCK+="    ${ROOT_DIRECTIVE}\n"
SITE_BLOCK+="    encode gzip\n"
SITE_BLOCK+="    ${FASTCGI_DIRECTIVE}\n"
SITE_BLOCK+="    file_server\n"
SITE_BLOCK+="    ${EXTRA_HEADER}\n"
SITE_BLOCK+="}\n"

if [[ -n "$EMAIL" ]]; then
  GLOBAL_BLOCK="{\n    email ${EMAIL}\n}\n\n"
else
  GLOBAL_BLOCK=""
fi

# Merge into Caddyfile (simple strategy: replace existing Crucible block or append)
if [[ -f "$CADDYFILE" ]] && grep -q "Crucible" "$CADDYFILE"; then
  run cp "$CADDYFILE" "${CADDYFILE}${BACKUP_SUFFIX}" || true
  awk -v block="$SITE_BLOCK" 'BEGIN{printed=0} /Crucible BEGIN/{print;print block;printed=1;skip=1} /Crucible END/{print;skip=0;next} !skip{print} END{if(!printed)print block}' "$CADDYFILE" | run tee "$CADDYFILE" >/dev/null
else
  # Append with markers
  if [[ -f "$CADDYFILE" ]]; then run cp "$CADDYFILE" "${CADDYFILE}${BACKUP_SUFFIX}" || true; fi
  { [[ -n "$GLOBAL_BLOCK" ]] && printf "%s" "$GLOBAL_BLOCK"; echo "# Crucible Laravel Block BEGIN"; printf "%s" "$SITE_BLOCK"; echo "# Crucible Laravel Block END"; } | run tee -a "$CADDYFILE" >/dev/null
fi

# Reload services
if systemctl list-unit-files | grep -q "$SERVICE_FPM"; then
  run systemctl restart "$SERVICE_FPM" || true
fi
run systemctl reload caddy 2>/dev/null || run systemctl restart caddy || true

if command_exists gum; then
  gum style --foreground 82 --bold "Caddy Laravel preparation complete" \
    "\nDomain: ${DOMAIN:-:80}\nRoot: $PUBLIC_DIR\nPHP-FPM pool: $(basename "$POOL_FILE")"
else
  echo "[caddy-laravel] Complete. Root: $PUBLIC_DIR Domain: ${DOMAIN:-:80}"
fi
