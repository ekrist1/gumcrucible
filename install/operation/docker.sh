#!/usr/bin/env bash
# Docker Management UI for Crucible (containers and images)
set -euo pipefail

if ! command -v gum >/dev/null 2>&1; then
  echo "[docker-ui][error] gum required" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_docker() {
  if command_exists docker; then return 0; fi
  gum style --foreground 214 --bold "Docker is not installed."
  if gum confirm "Install Docker & Compose now?"; then
    local installer="${SCRIPT_DIR}/../services/docker.sh"
    if [[ -f "$installer" ]]; then
      bash "$installer"
    else
      gum style --foreground 196 "Missing installer: install/services/docker.sh"
      return 1
    fi
  else
    return 1
  fi
}

header() {
  clear || true
  gum style --border normal --margin "1 2" --padding "1 2" --border-foreground 63 --foreground 207 --bold "Docker Management"
}

list_running_containers() {
  ensure_docker || return 1
  header
  if ! docker ps --format '{{.ID}}||{{.Names}}||{{.Image}}||{{.Status}}||{{.Ports}}' | awk -F'||' '{printf "%-12s  %-25s  %-35s  %-20s  %s\n", $1, $2, $3, $4, $5}' | gum pager; then
    gum style --faint "No running containers or display aborted."
  fi
}

list_all_containers() {
  ensure_docker || return 1
  header
  if ! docker ps -a --format '{{.ID}}||{{.Names}}||{{.Image}}||{{.Status}}||{{.Ports}}' | awk -F'||' '{printf "%-12s  %-25s  %-35s  %-20s  %s\n", $1, $2, $3, $4, $5}' | gum pager; then
    gum style --faint "No containers or display aborted."
  fi
}

select_container() {
  # args: filter (e.g., running|stopped|all)
  ensure_docker || return 1
  local filter=${1:-all}
  local cmd=(docker ps)
  case "$filter" in
    running) cmd=(docker ps) ;;
    stopped) cmd=(docker ps -a --filter status=exited --filter status=created) ;;
    all) cmd=(docker ps -a) ;;
  esac
  local list
  if ! list=$("${cmd[@]}" --format '{{.ID}}||{{.Names}}||{{.Image}}||{{.Status}}'); then
    echo ""; return 1
  fi
  [[ -z "$list" ]] && echo "" && return 1
  local choice
  choice=$(echo "$list" | awk -F'||' '{printf "%-25s | %-12s | %-30s | %s :: %s\n", $2, $1, $3, $4, $1}' | gum choose --header "Select container") || { echo ""; return 1; }
  echo "$choice" | awk -F':: ' '{print $2}'
}

select_image() {
  ensure_docker || return 1
  local list
  if ! list=$(docker images --format '{{.Repository}}:{{.Tag}}||{{.ID}}||{{.Size}}||{{.CreatedSince}}'); then
    echo ""; return 1
  fi
  [[ -z "$list" ]] && echo "" && return 1
  local choice
  choice=$(echo "$list" | awk -F'||' '{printf "%-35s | %-12s | %-10s | %s :: %s\n", $1, $2, $3, $4, $2}' | gum choose --header "Select image") || { echo ""; return 1; }
  echo "$choice" | awk -F':: ' '{print $2}'
}

container_logs() {
  ensure_docker || return 1
  local id
  id=$(select_container all) || return 1
  [[ -z "$id" ]] && return 1
  local follow=no
  gum confirm "Follow logs?" && follow=yes
  if [[ $follow == yes ]]; then
    docker logs -f --tail 200 "$id"
  else
    docker logs --tail 200 "$id" | gum pager
  fi
}

container_stop() {
  ensure_docker || return 1
  local id
  id=$(select_container running) || return 1
  [[ -z "$id" ]] && return 0
  gum spin --spinner line --title "Stopping container $id" -- docker stop "$id" >/dev/null 2>&1 || true
}

container_start() {
  ensure_docker || return 1
  local id
  id=$(select_container stopped) || return 1
  [[ -z "$id" ]] && return 0
  gum spin --spinner line --title "Starting container $id" -- docker start "$id" >/dev/null 2>&1 || true
}

container_restart() {
  ensure_docker || return 1
  local id
  id=$(select_container all) || return 1
  [[ -z "$id" ]] && return 0
  gum spin --spinner line --title "Restarting container $id" -- docker restart "$id" >/dev/null 2>&1 || true
}

container_remove() {
  ensure_docker || return 1
  local id
  id=$(select_container all) || return 1
  [[ -z "$id" ]] && return 0
  if gum confirm "Force remove container $id? (stopped required otherwise)"; then
    gum spin --spinner line --title "Removing container $id" -- docker rm -f "$id" >/dev/null 2>&1 || true
  else
    gum spin --spinner line --title "Removing container $id" -- docker rm "$id" >/dev/null 2>&1 || true
  fi
}

image_list() {
  ensure_docker || return 1
  header
  docker images --format '{{.Repository}}:{{.Tag}}||{{.ID}}||{{.Size}}||{{.CreatedSince}}' | awk -F'||' '{printf "%-40s  %-14s  %-10s  %s\n", $1, $2, $3, $4}' | gum pager || true
}

image_remove() {
  ensure_docker || return 1
  local img
  img=$(select_image) || return 1
  [[ -z "$img" ]] && return 0
  if gum confirm "Force remove image $img?"; then
    gum spin --spinner line --title "Removing image $img" -- docker rmi -f "$img" >/dev/null 2>&1 || true
  else
    gum spin --spinner line --title "Removing image $img" -- docker rmi "$img" >/dev/null 2>&1 || true
  fi
}

image_pull() {
  ensure_docker || return 1
  local ref
  ref=$(gum input --placeholder "e.g. nginx:latest") || return 1
  [[ -z "$ref" ]] && return 0
  gum spin --spinner line --title "Pulling $ref" -- docker pull "$ref" >/dev/null 2>&1 || true
}

docker_stats() {
  ensure_docker || return 1
  header
  docker stats --no-stream | gum pager || true
}

prune_dangling_images() {
  ensure_docker || return 1
  if gum confirm "Remove dangling images?"; then
    gum spin --spinner line --title "Pruning dangling images" -- docker image prune -f >/dev/null 2>&1 || true
  fi
}

system_prune() {
  ensure_docker || return 1
  if gum confirm "docker system prune -a (remove unused images, containers, networks)?"; then
    gum spin --spinner line --title "Pruning unused docker data" -- docker system prune -a -f >/dev/null 2>&1 || true
  fi
}

exec_shell() {
  ensure_docker || return 1
  local id
  id=$(select_container running) || return 1
  [[ -z "$id" ]] && return 0
  # Try bash then sh
  if docker exec "$id" bash -lc 'exit' >/dev/null 2>&1; then
    gum style --faint "Entering bash in $id (exit to return)"
    docker exec -it "$id" bash || true
  else
    gum style --faint "Entering sh in $id (exit to return)"
    docker exec -it "$id" sh || true
  fi
}

main_menu() {
  while true; do
    header
    local choice
    choice=$(gum choose --header "Docker Management" \
      "List running containers" \
      "List all containers" \
      "Container logs" \
      "Stop container" \
      "Start container" \
      "Restart container" \
      "Remove container" \
      "Open shell in container" \
      "Docker stats" \
      "List images" \
      "Pull image" \
      "Remove image" \
      "Prune dangling images" \
      "System prune" \
      "Back") || return 0

    case "$choice" in
      "List running containers") list_running_containers ;;
      "List all containers") list_all_containers ;;
      "Container logs") container_logs ;;
      "Stop container") container_stop ;;
      "Start container") container_start ;;
      "Restart container") container_restart ;;
      "Remove container") container_remove ;;
      "Open shell in container") exec_shell ;;
      "Docker stats") docker_stats ;;
      "List images") image_list ;;
      "Pull image") image_pull ;;
      "Remove image") image_remove ;;
      "Prune dangling images") prune_dangling_images ;;
      "System prune") system_prune ;;
      Back) return 0 ;;
    esac

    gum confirm "Another Docker action?" || break
  done
}

main_menu "$@"
