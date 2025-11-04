#!/usr/bin/env bash
# Next.js application deployer with Nginx reverse proxy (conf.d)
# - Supports cloning remote repository or using existing path
# - Installs Node.js dependencies, builds app, and sets up systemd service running `next start`
# - Generates Nginx config in /etc/nginx/conf.d/<domain>.conf
# - Requires Nginx; exits with error if not installed
set -euo pipefail

export CRUCIBLE_COMPONENT="nextjs_nginx"

PROGRESS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/progress.sh"
[[ -f "$PROGRESS_LIB" ]] && source "$PROGRESS_LIB"

if ! command -v gum >/dev/null 2>&1; then
  echo "[nextjs-nginx][warn] gum not found; proceeding without UI prompts" >&2
  gum() { shift || true; "$@"; }
fi

command_exists() { command -v "$1" >/dev/null 2>&1; }
need_sudo() { if [[ $EUID -ne 0 ]]; then command_exists sudo && echo sudo; fi; }

# Inputs
DOMAIN=""
PROJECT_PATH=""
REPOSITORY=""
BRANCH="main"
PORT="3000"
FORCE=false
UPDATE=false
ENVIRONMENT="production"
RUNTIME_MODE="systemd" # options: systemd|pm2|static
NODE_BIN="node"
NPM_BIN="npm"
PNPM_BIN="pnpm"
YARN_BIN="yarn"
PKG_MANAGER=""

# Check Nginx presence early
require_nginx() {
  if ! command_exists nginx; then
    gum style --foreground 196 --bold "ERROR: Nginx is not installed."
    gum style --faint "Install it via ./install/services/nginx.sh"
    exit 1
  fi
}

pick_pkg_manager() {
  # Prefer pnpm > yarn > npm based on availability of binaries
  if command_exists pnpm; then PKG_MANAGER="pnpm"; return; fi
  if command_exists yarn; then PKG_MANAGER="yarn"; return; fi
  PKG_MANAGER="npm"
}

install_node_deps() {
  pick_pkg_manager
  local title="Installing dependencies ($PKG_MANAGER)"
  case "$PKG_MANAGER" in
    pnpm)
      gum spin --spinner line --title "$title" -- bash -c "cd '$PROJECT_PATH' && pnpm install --frozen-lockfile || pnpm install" ;;
    yarn)
      gum spin --spinner line --title "$title" -- bash -c "cd '$PROJECT_PATH' && yarn install --frozen-lockfile || yarn install" ;;
    npm|*)
      gum spin --spinner line --title "$title" -- bash -c "cd '$PROJECT_PATH' && npm ci || npm install" ;;
  esac
}

build_next() {
  local title="Building Next.js app"
  gum spin --spinner line --title "$title" -- bash -c "cd '$PROJECT_PATH' && $PKG_MANAGER run build"
}

ensure_systemd_service() {
  local sudo_cmd; sudo_cmd=$(need_sudo || true)
  local svc_name="next_${DOMAIN//./_}"
  local svc_file="/etc/systemd/system/${svc_name}.service"
  local exec_cmd
  case "$PKG_MANAGER" in
    pnpm) exec_cmd="pnpm exec next start -p $PORT" ;;
    yarn) exec_cmd="yarn next start -p $PORT" ;;
    npm|*) exec_cmd="npx --no-install next start -p $PORT" ;;
  esac

  # Create service
  cat <<EOF | ${sudo_cmd:-} tee "$svc_file" >/dev/null
[Unit]
Description=Next.js app for $DOMAIN
After=network.target

[Service]
Type=simple
WorkingDirectory=$PROJECT_PATH
Environment=NODE_ENV=$ENVIRONMENT
ExecStart=/bin/bash -lc '$exec_cmd'
Restart=always
RestartSec=10
User=${SUDO_USER:-${USER}}

[Install]
WantedBy=multi-user.target
EOF

  gum spin --spinner line --title "Reloading systemd" -- bash -c "${sudo_cmd:-} systemctl daemon-reload"
  gum spin --spinner line --title "Enabling Next.js service" -- bash -c "${sudo_cmd:-} systemctl enable --now '$svc_name'"
}

ensure_pm2_process() {
  if ! command_exists pm2; then
    gum style --foreground 196 --bold "ERROR: PM2 is not installed."
    gum style --faint "Install with: npm i -g pm2"
    exit 1
  fi
  local svc_name="next_${DOMAIN//./_}"
  local start_cmd
  case "$PKG_MANAGER" in
    pnpm) start_cmd="pnpm exec next start -p $PORT" ;;
    yarn) start_cmd="yarn next start -p $PORT" ;;
    npm|*) start_cmd="npx --no-install next start -p $PORT" ;;
  esac
  gum spin --spinner line --title "Starting PM2 process ($svc_name)" -- bash -c "pm2 start --name '$svc_name' --cwd '$PROJECT_PATH' -- bash -lc '$start_cmd' 2>/dev/null || pm2 restart '$svc_name' --update-env"
  # Enable PM2 on boot
  local sudo_cmd; sudo_cmd=$(need_sudo || true)
  ${sudo_cmd:-} pm2 startup -u "${SUDO_USER:-${USER}}" --hp "$HOME" >/dev/null 2>&1 || true
  pm2 save >/dev/null 2>&1 || true
}

create_nginx_conf_ssr() {
  local sudo_cmd; sudo_cmd=$(need_sudo || true)
  local conf="/etc/nginx/conf.d/${DOMAIN}.conf"
  local upstream_name="next_${DOMAIN//./_}"
  ${sudo_cmd:-} mkdir -p /etc/nginx/conf.d >/dev/null 2>&1 || true

  # Minimal reverse proxy config with gzip and headers
  cat <<EOF | ${sudo_cmd:-} tee "$conf" >/dev/null
upstream $upstream_name {
    server 127.0.0.1:$PORT;
    keepalive 64;
}

server {
    listen 80;
    server_name $DOMAIN;

    # Static assets can be served directly if exported; for SSR we proxy to Next
    location /_next/static/ {
        alias $PROJECT_PATH/.next/static/;
        access_log off;
        expires 1y;
        add_header Cache-Control "public, max-age=31536000, immutable";
    }

    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass http://$upstream_name;
    }
}
EOF

  # Test and reload Nginx
  if ! ${sudo_cmd:-} nginx -t >/dev/null 2>&1; then
    gum style --foreground 196 "Error: Invalid Nginx configuration"
    ${sudo_cmd:-} nginx -t || true
    exit 1
  fi
  # Ensure nginx is running
  if ! systemctl is-active --quiet nginx 2>/dev/null; then
    gum spin --spinner line --title "Starting Nginx" -- bash -c "${sudo_cmd:-} systemctl enable --now nginx"
  fi
  gum spin --spinner line --title "Reloading Nginx" -- bash -c "${sudo_cmd:-} systemctl reload nginx"
}

create_nginx_conf_static() {
  local sudo_cmd; sudo_cmd=$(need_sudo || true)
  local conf="/etc/nginx/conf.d/${DOMAIN}.conf"
  ${sudo_cmd:-} mkdir -p /etc/nginx/conf.d >/dev/null 2>&1 || true

  cat <<EOF | ${sudo_cmd:-} tee "$conf" >/dev/null
server {
    listen 80;
    server_name $DOMAIN;
    root $PROJECT_PATH/out;
    index index.html;

    # Long-term caching for Next exported assets
    location /_next/ {
        access_log off;
        expires 1y;
        add_header Cache-Control "public, max-age=31536000, immutable";
        try_files \$uri \$uri/ =404;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

  if ! ${sudo_cmd:-} nginx -t >/dev/null 2>&1; then
    gum style --foreground 196 "Error: Invalid Nginx configuration"
    ${sudo_cmd:-} nginx -t || true
    exit 1
  fi
  if ! systemctl is-active --quiet nginx 2>/dev/null; then
    gum spin --spinner line --title "Starting Nginx" -- bash -c "${sudo_cmd:-} systemctl enable --now nginx"
  fi
  gum spin --spinner line --title "Reloading Nginx" -- bash -c "${sudo_cmd:-} systemctl reload nginx"
}

clone_or_update_repo() {
  local parent; parent=$(dirname "$PROJECT_PATH")
  local sudo_cmd; sudo_cmd=$(need_sudo || true)
  [[ -d "$parent" ]] || ${sudo_cmd:-} mkdir -p "$parent"

  if [[ -n "$REPOSITORY" ]]; then
    if [[ -d "$PROJECT_PATH/.git" ]]; then
      UPDATE=true
    fi
    if [[ "$UPDATE" == "true" ]]; then
      gum spin --spinner line --title "Updating repository" -- bash -c "cd '$PROJECT_PATH' && git pull --ff-only origin '$BRANCH'"
    else
      if [[ "$FORCE" == "true" && -d "$PROJECT_PATH" ]]; then
        ${sudo_cmd:-} rm -rf "$PROJECT_PATH"
      fi
      gum spin --spinner line --title "Cloning repository" -- bash -c "git clone --branch '$BRANCH' '$REPOSITORY' '$PROJECT_PATH'"
    fi
  else
    # No repo provided; ensure directory exists
    [[ -d "$PROJECT_PATH" ]] || ${sudo_cmd:-} mkdir -p "$PROJECT_PATH"
  fi
}

validate_requirements() {
  local missing=()
  command_exists git || missing+=("git")
  # Need at least one of node/npm/yarn/pnpm; we'll install deps via chosen manager existing on system
  command_exists node || missing+=("node")
  if [[ ${#missing[@]} -gt 0 ]]; then
    gum style --foreground 196 --bold "Missing dependencies: ${missing[*]}"
    gum style --faint "Install Node.js and Git from Core Services first."
    exit 1
  fi
}

get_input() {
  clear || true
  gum style --foreground 45 --bold "Next.js + Nginx Deployment"
  gum style --faint "Deploy a Next.js app behind Nginx (conf.d)"
  echo

  while [[ -z "$DOMAIN" ]]; do
    DOMAIN=$(gum input --placeholder "example.com" --prompt "Domain: ") || exit 0
    [[ -n "$DOMAIN" ]] || gum style --foreground 196 "Domain is required" && echo
  done

  REPOSITORY=$(gum input --placeholder "https://github.com/user/repo.git (optional)" --prompt "Repository URL: ") || exit 0
  BRANCH=$(gum input --placeholder "main" --prompt "Branch: " --value "main") || exit 0

  local default_path="/var/www/$DOMAIN"
  PROJECT_PATH=$(gum input --placeholder "$default_path" --prompt "Project path: " --value "$default_path") || exit 0
  [[ -n "$PROJECT_PATH" ]] || PROJECT_PATH="$default_path"

  # Choose runtime mode
  local runtime_choice
  runtime_choice=$(gum choose --header "Runtime mode" \
    "SSR via systemd" \
    "SSR via PM2" \
    "Static export (Nginx only)" \
    "Cancel") || exit 0
  case "$runtime_choice" in
    "Cancel") exit 0 ;;
    "SSR via PM2") RUNTIME_MODE="pm2" ;;
    "Static export (Nginx only)") RUNTIME_MODE="static" ;;
    *) RUNTIME_MODE="systemd" ;;
  esac

  if [[ "$RUNTIME_MODE" != "static" ]]; then
    PORT=$(gum input --placeholder "3000" --prompt "App port (Next.js start -p): " --value "3000") || exit 0
    [[ -n "$PORT" ]] || PORT="3000"
  fi

  if gum confirm "Advanced options?"; then
    ENVIRONMENT=$(gum input --placeholder "production" --prompt "NODE_ENV: " --value "production") || exit 0
    if [[ -d "$PROJECT_PATH" ]] && gum confirm "Directory exists. Force overwrite on clone?"; then
      FORCE=true
    fi
  fi

  echo
  gum style --foreground 82 --bold "Summary"
  gum style --faint "Domain: $DOMAIN"
  [[ -n "$REPOSITORY" ]] && gum style --faint "Repo: $REPOSITORY (@$BRANCH)"
  gum style --faint "Path: $PROJECT_PATH"
  [[ "$RUNTIME_MODE" != "static" ]] && gum style --faint "Port: $PORT"
  gum style --faint "Mode: $RUNTIME_MODE"
  gum style --faint "NODE_ENV: $ENVIRONMENT"
  echo
  gum confirm "Proceed?" || exit 0
}

setup_permissions() {
  local sudo_cmd; sudo_cmd=$(need_sudo || true)
  # Default to nginx if present else www-data else current user
  local web_user="www-data"
  id nginx >/dev/null 2>&1 && web_user="nginx"
  id "$web_user" >/dev/null 2>&1 || web_user="${SUDO_USER:-${USER}}"
  ${sudo_cmd:-} chown -R "$web_user:$web_user" "$PROJECT_PATH" || true
}

health_check() {
  if ! declare -f health_check_summary >/dev/null 2>&1; then
    return 0
  fi
  local svc_name="next_${DOMAIN//./_}"
  local checks=(
    "test -d '$PROJECT_PATH'"
    "test -f '/etc/nginx/conf.d/${DOMAIN}.conf'"
    "nginx -t >/dev/null 2>&1"
    "systemctl is-active --quiet nginx"
  )
  if [[ "$RUNTIME_MODE" == "systemd" ]]; then
    checks+=("systemctl is-active --quiet $svc_name")
  elif [[ "$RUNTIME_MODE" == "pm2" ]]; then
    if command_exists pm2; then
      checks+=("pm2 describe '$svc_name' >/dev/null 2>&1")
    fi
  elif [[ "$RUNTIME_MODE" == "static" ]]; then
    checks+=("test -f '$PROJECT_PATH/out/index.html'")
  fi
  health_check_summary "Next.js + Nginx" "${checks[@]}"
}

main() {
  require_nginx
  validate_requirements
  get_input
  clone_or_update_repo
  install_node_deps
  if [[ "$RUNTIME_MODE" == "static" ]]; then
    gum spin --spinner line --title "Building (export)" -- bash -c "cd '$PROJECT_PATH' && $PKG_MANAGER run build && $PKG_MANAGER exec next export || npx --no-install next export"
    create_nginx_conf_static
  else
    build_next
    if [[ "$RUNTIME_MODE" == "pm2" ]]; then
      ensure_pm2_process
    else
      ensure_systemd_service
    fi
    create_nginx_conf_ssr
  fi
  setup_permissions

  gum style --foreground 82 --bold "Next.js + Nginx deployment complete!"
  gum style --faint "Domain: http://$DOMAIN"
  gum style --faint "Config: /etc/nginx/conf.d/${DOMAIN}.conf"
  gum style --faint "Path: $PROJECT_PATH"
  if [[ "$RUNTIME_MODE" == "systemd" ]]; then
    gum style --faint "Service: systemctl status next_${DOMAIN//./_}"
  elif [[ "$RUNTIME_MODE" == "pm2" ]]; then
    gum style --faint "PM2: pm2 status next_${DOMAIN//./_}"
  else
    gum style --faint "Static root: $PROJECT_PATH/out"
  fi

  health_check
}

main "$@"
