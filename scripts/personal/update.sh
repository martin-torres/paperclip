#!/usr/bin/env bash
# Fetch this fork's default branch and apply it when the tree is clean.
# A scheduled run does nothing until 10 days have passed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
paperclip_infer_home_from_script "$0"

SCHEDULED=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Update a personal Paperclip checkout from origin.

Usage:
  bash scripts/update.sh
  bash scripts/personal/update.sh
  ~/.paperclip/personal/bin/update.sh
  bash scripts/personal/update.sh --scheduled

With no flag, the command checks origin immediately.
--scheduled returns without changes until 10 days have passed
since the last successful check. The schedule is 10 days, not 10 minutes.

The command pulls only when all of these are true:
  - the checkout is on the update branch (default: master)
  - git status is clean
  - origin has new commits

It then installs dependencies, rebuilds the small boot set or the
Docker image, restarts the service, and appends a log line.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --scheduled) SCHEDULED=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) paperclip_die "unknown option: $1" ;;
  esac
done

if [ "${PAPERCLIP_PERSONAL_SOURCE_ONLY:-}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

HOME_DIR="$(paperclip_home_dir)"
PERSONAL_DIR="$(paperclip_personal_dir)"
STATE_FILE="$(paperclip_state_file)"
LOG_DIR="$PERSONAL_DIR/logs"
LOCK_DIR="$PERSONAL_DIR/update.lock"
STAMP_FILE="$(paperclip_update_stamp_file)"
mkdir -p "$LOG_DIR"

log_line() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
  printf '%s\n' "$line" | tee -a "$LOG_DIR/update.log"
}

if [ -f "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  set -a
  . "$STATE_FILE"
  set +a
fi

BRANCH="${PAPERCLIP_UPDATE_BRANCH:-$PAPERCLIP_UPDATE_BRANCH_DEFAULT}"
CHECKOUT="${PAPERCLIP_CHECKOUT:-}"
if [ -z "$CHECKOUT" ]; then
  CHECKOUT="$(paperclip_absdir "$SCRIPT_DIR/../..")"
fi
MODE="${PAPERCLIP_MODE:-source}"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ "$SCHEDULED" = "1" ]; then
    log_line "skip: another update is running"
    exit 0
  fi
  paperclip_die "another update is already running ($LOCK_DIR)"
fi
cleanup_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup_lock EXIT

if [ "$SCHEDULED" = "1" ] && ! paperclip_update_is_due "$STAMP_FILE"; then
  log_line "skip: not due (interval ${PAPERCLIP_UPDATE_INTERVAL_SECONDS}s, 10 days)"
  exit 0
fi

[ -d "$CHECKOUT/.git" ] || paperclip_die "checkout is not a git repository: $CHECKOUT"

plan="$(paperclip_git_plan "$CHECKOUT" "$BRANCH")"
log_line "plan=$plan checkout=$CHECKOUT branch=$BRANCH mode=$MODE"

case "$plan" in
  unchanged)
    date +%s >"$STAMP_FILE"
    log_line "origin/$BRANCH matches HEAD. No rebuild."
    exit 0
    ;;
  dirty)
    log_line "skip: worktree is not clean. Commit or stash, then run update.sh again."
    exit 0
    ;;
  wrong-branch)
    log_line "skip: checkout is not on $BRANCH. Auto-update does not switch branches."
    exit 0
    ;;
  update) ;;
  *) paperclip_die "unexpected git plan: $plan" ;;
esac

if [ "$DRY_RUN" = "1" ]; then
  log_line "dry-run: would fast-forward, rebuild, and restart"
  exit 0
fi

log_line "fast-forward origin/$BRANCH"
git -C "$CHECKOUT" pull --ff-only origin "$BRANCH"

rebuild_source() {
  local node_bin node_dir
  node_bin="${PAPERCLIP_NODE:-node}"
  node_dir="$(dirname "$node_bin")"
  PATH="$node_dir:$PATH"
  export PATH
  export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
  cd "$CHECKOUT"
  if [ -n "${PAPERCLIP_UPDATE_REBUILD_CMD:-}" ]; then
    # Test hook. Production updates leave this unset.
    # shellcheck disable=SC2090
    eval "$PAPERCLIP_UPDATE_REBUILD_CMD"
    return
  fi
  unset CI || true
  if ! corepack pnpm install --frozen-lockfile; then
    log_line "pnpm-lock.yaml does not match the manifests. Installing without a frozen lockfile."
    lock_dirty=0
    if [ -n "$(git -C "$CHECKOUT" status --porcelain -- pnpm-lock.yaml)" ]; then
      lock_dirty=1
    fi
    corepack pnpm install --no-frozen-lockfile
    if [ "$lock_dirty" = "0" ]; then
      git -C "$CHECKOUT" checkout -- pnpm-lock.yaml
    fi
  fi
  "$node_bin" scripts/ensure-plugin-build-deps.mjs
}

restart_source() {
  if [ -n "${PAPERCLIP_UPDATE_RESTART_CMD:-}" ]; then
    # shellcheck disable=SC2090
    eval "$PAPERCLIP_UPDATE_RESTART_CMD"
    return
  fi
  if paperclip_user_systemd_works; then
    systemctl --user restart "$PAPERCLIP_SYSTEMD_SERVICE"
    return
  fi
  if paperclip_launchd_works; then
    launchctl kickstart -k "gui/$(id -u)/$PAPERCLIP_LAUNCHD_LABEL"
    return
  fi
  local pid_file="$PERSONAL_DIR/server.pid"
  if [ -f "$pid_file" ]; then
    kill "$(cat "$pid_file")" 2>/dev/null || true
  fi
}

if [ "$MODE" = "docker" ]; then
  if [ -n "${PAPERCLIP_UPDATE_REBUILD_CMD:-}" ]; then
    # shellcheck disable=SC2090
    eval "$PAPERCLIP_UPDATE_REBUILD_CMD"
  else
    data_dir="$HOME_DIR/docker-data"
    env_file="$PERSONAL_DIR/docker.env"
    export PAPERCLIP_PUBLISH_PORT="${PAPERCLIP_PORT:-$PAPERCLIP_DEFAULT_PORT}"
    export PAPERCLIP_DOCKER_ENV_FILE="$env_file"
    export PAPERCLIP_DOCKER_DATA_DIR="$data_dir"
    export PAPERCLIP_DOCKER_MEMORY PAPERCLIP_DOCKER_MEMORY_RESERVATION
    docker compose -f "$CHECKOUT/scripts/personal/docker-compose.yml" up -d --build
    docker update \
      --memory="$PAPERCLIP_DOCKER_MEMORY" \
      --memory-swap="$PAPERCLIP_DOCKER_MEMORY" \
      --memory-reservation="$PAPERCLIP_DOCKER_MEMORY_RESERVATION" \
      "$PAPERCLIP_DOCKER_CONTAINER"
  fi
  if [ -n "${PAPERCLIP_UPDATE_RESTART_CMD:-}" ]; then
    # shellcheck disable=SC2090
    eval "$PAPERCLIP_UPDATE_RESTART_CMD"
  fi
else
  rebuild_source
  restart_source
fi

date +%s >"$STAMP_FILE"
log_line "updated to $(git -C "$CHECKOUT" rev-parse --short HEAD)"
