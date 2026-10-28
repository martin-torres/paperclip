#!/usr/bin/env bash
# Stop the personal Paperclip service and remove its scheduler.
# Instance data and the git checkout stay unless you pass a purge flag.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
paperclip_infer_home_from_script "$0"

PURGE_DATA=0
REMOVE_CHECKOUT=0

usage() {
  cat <<'EOF'
Uninstall the personal Paperclip service.

Usage:
  bash scripts/uninstall.sh
  bash scripts/personal/uninstall.sh [--purge-data] [--remove-checkout]

The default command stops the service and removes the systemd unit,
launchd agent, cron block, and supervisor. It keeps:

  - ~/.paperclip/instances (config, database, secrets, uploads)
  - the Docker data directory
  - the git checkout

--purge-data deletes instance data and the Docker data directory.
--remove-checkout deletes the checkout only when it is ~/paperclip.
A checkout you cloned somewhere else, including a developer working
tree, is left in place.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --purge-data) PURGE_DATA=1; shift ;;
    --remove-checkout) REMOVE_CHECKOUT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) paperclip_die "unknown option: $1" ;;
  esac
done

HOME_DIR="$(paperclip_home_dir)"
PERSONAL_DIR="$(paperclip_personal_dir)"
STATE_FILE="$(paperclip_state_file)"
if [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  set -a
  . "$STATE_FILE"
  set +a
fi

MODE="${PAPERCLIP_MODE:-source}"
CHECKOUT="${PAPERCLIP_CHECKOUT:-}"

stop_pid_and_children() {
  local pid="$1"
  local child
  [ -n "$pid" ] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  for child in $(ps -o pid= --ppid "$pid" 2>/dev/null || true); do
    stop_pid_and_children "$child"
  done
}

stop_embedded_postgres() {
  local data_dir="$1"
  local pid args
  [ -n "$data_dir" ] || return 0
  ps -eo pid=,args= | while read -r pid args; do
    case "$args" in
      *postgres*"$data_dir"*)
        kill -TERM "$pid" 2>/dev/null || true
        ;;
    esac
  done
}

stop_source() {
  if paperclip_user_systemd_works; then
    systemctl --user disable --now "$PAPERCLIP_SYSTEMD_SERVICE" >/dev/null 2>&1 || true
    systemctl --user disable --now "$PAPERCLIP_SYSTEMD_TIMER" >/dev/null 2>&1 || true
    rm -f "${HOME}/.config/systemd/user/$PAPERCLIP_SYSTEMD_SERVICE" \
      "${HOME}/.config/systemd/user/$PAPERCLIP_SYSTEMD_TIMER" \
      "${HOME}/.config/systemd/user/paperclip-personal-update.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  if paperclip_launchd_works; then
    launchctl bootout "gui/$(id -u)/$PAPERCLIP_LAUNCHD_LABEL" >/dev/null 2>&1 || true
    launchctl bootout "gui/$(id -u)/$PAPERCLIP_LAUNCHD_UPDATE_LABEL" >/dev/null 2>&1 || true
    rm -f "${HOME}/Library/LaunchAgents/${PAPERCLIP_LAUNCHD_LABEL}.plist" \
      "${HOME}/Library/LaunchAgents/${PAPERCLIP_LAUNCHD_UPDATE_LABEL}.plist"
  fi
  if [ -f "$PERSONAL_DIR/supervise.pid" ]; then
    stop_pid_and_children "$(tr -cd '0-9' <"$PERSONAL_DIR/supervise.pid")"
  fi
  if [ -f "$PERSONAL_DIR/server.pid" ]; then
    stop_pid_and_children "$(tr -cd '0-9' <"$PERSONAL_DIR/server.pid")"
  fi
  stop_embedded_postgres "$HOME_DIR/instances/default/db"
  rm -f "$PERSONAL_DIR/supervise.pid" "$PERSONAL_DIR/server.pid"
}

stop_docker() {
  if paperclip_have docker && [ -n "$CHECKOUT" ] && [ -f "$CHECKOUT/scripts/personal/docker-compose.yml" ]; then
    export PAPERCLIP_PUBLISH_PORT="${PAPERCLIP_PORT:-$PAPERCLIP_DEFAULT_PORT}"
    export PAPERCLIP_DOCKER_ENV_FILE="$PERSONAL_DIR/docker.env"
    export PAPERCLIP_DOCKER_DATA_DIR="$HOME_DIR/docker-data"
    docker compose -f "$CHECKOUT/scripts/personal/docker-compose.yml" down || true
  elif paperclip_have docker; then
    docker rm -f "$PAPERCLIP_DOCKER_CONTAINER" >/dev/null 2>&1 || true
  fi
}

if [ "$MODE" = "docker" ]; then
  stop_docker
else
  stop_source
fi

if paperclip_have crontab; then
  existing="$(crontab -l 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    filtered="$(printf '%s\n' "$existing" | paperclip_filter_cron_block)"
    printf '%s\n' "$filtered" | crontab - || true
  fi
fi

if [ "$PURGE_DATA" = "1" ]; then
  paperclip_log "Removing instance data under $HOME_DIR"
  rm -rf "$HOME_DIR/instances" "$HOME_DIR/docker-data" "$PERSONAL_DIR/docker.env"
else
  paperclip_log "Kept instance data under $HOME_DIR"
fi

rm -f "$PERSONAL_DIR/bin/update.sh" "$PERSONAL_DIR/bin/run-source.sh" "$PERSONAL_DIR/bin/supervise.sh"
rm -f "$STATE_FILE"

if [ "$REMOVE_CHECKOUT" = "1" ] && [ -n "$CHECKOUT" ]; then
  default_checkout="${HOME}/paperclip"
  if [ "$CHECKOUT" = "$default_checkout" ]; then
    paperclip_log "Removing checkout $CHECKOUT"
    rm -rf "$CHECKOUT"
  else
    paperclip_log "Refusing to delete checkout outside $default_checkout: $CHECKOUT"
  fi
fi

paperclip_log "Personal service removed."
