#!/usr/bin/env bash
# Idempotent personal installer for this Paperclip fork.
# Linux and macOS use a source checkout and a user service.
# --docker is the VPS path: localhost publish, 1g memory cap.
set -euo pipefail

if [ -z "${BASH_SOURCE[0]:-}" ] || [ ! -f "${BASH_SOURCE[0]}" ]; then
  PIPED=1
else
  PIPED=0
fi

# A piped copy cannot see docker-compose.yml or lib.sh.
# Clone the fork, then run the checked-out script with the same arguments.
if [ "$PIPED" = "1" ]; then
  if [ "${PAPERCLIP_INSTALL_REEXEC:-}" = "1" ]; then
    printf '[paperclip-personal] error: piped installer re-exec loop\n' >&2
    exit 1
  fi
  command -v git >/dev/null 2>&1 || {
    printf '[paperclip-personal] error: git is required to clone the fork\n' >&2
    exit 1
  }
  dest="${PAPERCLIP_CHECKOUT:-${HOME:?HOME is required}/paperclip}"
  repo="${PAPERCLIP_REPO_URL:-https://github.com/martin-torres/paperclip.git}"
  branch="${PAPERCLIP_UPDATE_BRANCH:-master}"
  if [ ! -d "$dest/.git" ]; then
    if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null || true)" ]; then
      printf '[paperclip-personal] error: %s exists and is not a git checkout\n' "$dest" >&2
      exit 1
    fi
    git clone --branch "$branch" --single-branch "$repo" "$dest"
  fi
  export PAPERCLIP_INSTALL_REEXEC=1
  export PAPERCLIP_CHECKOUT="$dest"
  exec /usr/bin/env bash "$dest/scripts/personal/install.sh" "$@"
fi

usage() {
  cat <<'EOF'
Install this Paperclip fork on Linux or macOS.

From a checkout:
  bash scripts/personal/install.sh
  bash scripts/personal/install.sh --docker
  bash scripts/install.sh --personal
  bash scripts/install.sh --docker

One line, Linux always-on box or MacBook:
  curl -fsSL https://raw.githubusercontent.com/martin-torres/paperclip/master/scripts/personal/install.sh | bash

One line, Ubuntu VPS (Docker, bound to 127.0.0.1, 1g memory cap):
  curl -fsSL https://raw.githubusercontent.com/martin-torres/paperclip/master/scripts/personal/install.sh | bash -s -- --docker

The service listens on 127.0.0.1 port 9000.
If 9000 is busy, the first install uses 18790.
Set PAPERCLIP_PORT to choose another port.
A second run keeps the existing port, config, secrets, and database.

Options:
  --docker         Build and run the Docker image instead of a host service
  --personal       Host service (this is the default)
  --source         Same as --personal
  --full-build     Also run pnpm build (slow; includes the native runner)
  --switch-mode    Allow changing an existing source install to Docker, or the reverse
  --dry-run        Print the plan and exit
  -h, --help       Show this help
EOF
}

MODE="source"
FULL_BUILD=0
SWITCH_MODE=0
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --docker) MODE="docker"; shift ;;
    --personal|--source) MODE="source"; shift ;;
    --full-build) FULL_BUILD=1; shift ;;
    --switch-mode) SWITCH_MODE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf '[paperclip-personal] error: unknown option: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

HOME_DIR="$(paperclip_home_dir)"
PERSONAL_DIR="$(paperclip_personal_dir)"
STATE_FILE="$(paperclip_state_file)"
BRANCH="${PAPERCLIP_UPDATE_BRANCH:-$PAPERCLIP_UPDATE_BRANCH_DEFAULT}"
REPO_URL="$(paperclip_sanitize_git_url "${PAPERCLIP_REPO_URL:-$PAPERCLIP_DEFAULT_REPO_URL}")"

if [ -d "$SCRIPT_DIR/../.." ] && [ -f "$SCRIPT_DIR/../../package.json" ]; then
  DEFAULT_CHECKOUT="$(paperclip_absdir "$SCRIPT_DIR/../..")"
else
  DEFAULT_CHECKOUT="${HOME}/paperclip"
fi
CHECKOUT="${PAPERCLIP_CHECKOUT:-$DEFAULT_CHECKOUT}"

SAVED_MODE="$(paperclip_state_get PAPERCLIP_MODE)"
SAVED_PORT="$(paperclip_state_get PAPERCLIP_PORT)"
SAVED_CHECKOUT="$(paperclip_state_get PAPERCLIP_CHECKOUT)"
SAVED_BRANCH="$(paperclip_state_get PAPERCLIP_UPDATE_BRANCH)"
SAVED_NODE="$(paperclip_state_get PAPERCLIP_NODE)"
if [ -n "$SAVED_MODE" ] && [ "$SAVED_MODE" != "$MODE" ] && [ "$SWITCH_MODE" != "1" ]; then
  paperclip_die "Existing install mode is $SAVED_MODE. Re-run the same way, or pass --switch-mode. Data was not modified."
fi
if [ -n "$SAVED_CHECKOUT" ]; then
  CHECKOUT="$SAVED_CHECKOUT"
fi
if [ -n "$SAVED_BRANCH" ]; then
  BRANCH="$SAVED_BRANCH"
fi
if [ -n "$SAVED_NODE" ]; then
  PAPERCLIP_NODE="$SAVED_NODE"
fi

# An existing state port wins over a newly chosen port.
EXISTING_PORT="$SAVED_PORT"

if [ -n "$EXISTING_PORT" ]; then
  CHOSEN_PORT="$EXISTING_PORT"
else
  if [ "$DRY_RUN" = "1" ]; then
    CHOSEN_PORT="${PAPERCLIP_PORT:-$PAPERCLIP_DEFAULT_PORT}"
  else
    CHOSEN_PORT="$(paperclip_choose_port)"
  fi
fi

paperclip_log "mode=$MODE checkout=$CHECKOUT home=$HOME_DIR port=$CHOSEN_PORT branch=$BRANCH"
paperclip_log "bind=127.0.0.1 url=http://127.0.0.1:$CHOSEN_PORT"

if [ "$DRY_RUN" = "1" ]; then
  paperclip_log "dry-run: no files were written"
  if [ "$MODE" = "docker" ]; then
    paperclip_log "docker memory cap=$PAPERCLIP_DOCKER_MEMORY reservation=$PAPERCLIP_DOCKER_MEMORY_RESERVATION"
    paperclip_log "docker publish=127.0.0.1:$CHOSEN_PORT"
  else
    paperclip_log "service=systemd user, or launchd, or a direct supervisor when those are absent"
  fi
  exit 0
fi

paperclip_reject_odd_path "checkout" "$CHECKOUT"
paperclip_reject_odd_path "PAPERCLIP_HOME" "$HOME_DIR"
mkdir -p "$PERSONAL_DIR/bin" "$PERSONAL_DIR/logs" "$HOME_DIR"

ensure_checkout() {
  if [ -d "$CHECKOUT/.git" ]; then
    paperclip_log "Using existing checkout at $CHECKOUT"
    return
  fi
  if [ -e "$CHECKOUT" ] && [ -n "$(ls -A "$CHECKOUT" 2>/dev/null || true)" ]; then
    paperclip_die "$CHECKOUT exists and is not a git checkout"
  fi
  paperclip_have git || paperclip_die "git is required"
  git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$CHECKOUT"
}

node_prefix() {
  printf '%s\n' "$PERSONAL_DIR/node-v$PAPERCLIP_NODE_VERSION"
}

ensure_node() {
  if [ -n "${PAPERCLIP_NODE:-}" ] && [ -x "$PAPERCLIP_NODE" ] && paperclip_node_is_supported "$PAPERCLIP_NODE"; then
    return
  fi
  if paperclip_node_is_supported node; then
    PAPERCLIP_NODE="$(command -v node)"
    return
  fi
  local os arch name prefix url sums
  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *) paperclip_die "unsupported operating system $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) paperclip_die "unsupported architecture $(uname -m)" ;;
  esac
  prefix="$(node_prefix)"
  if [ ! -x "$prefix/bin/node" ]; then
    paperclip_have curl || paperclip_die "curl is required to download Node.js $PAPERCLIP_NODE_VERSION"
    name="node-v${PAPERCLIP_NODE_VERSION}-${os}-${arch}.tar.gz"
    url="https://nodejs.org/dist/v${PAPERCLIP_NODE_VERSION}/${name}"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/paperclip-node.XXXXXX")"
    curl -fsSL "$url" -o "$tmp/$name"
    curl -fsSL "https://nodejs.org/dist/v${PAPERCLIP_NODE_VERSION}/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt"
    sums="$(awk -v file="$name" '$2 == file { print $1 }' "$tmp/SHASUMS256.txt")"
    [ -n "$sums" ] || paperclip_die "Node.js tarball is missing from SHASUMS256.txt"
    if paperclip_have sha256sum; then
      actual="$(sha256sum "$tmp/$name" | awk '{ print $1 }')"
    else
      actual="$(shasum -a 256 "$tmp/$name" | awk '{ print $1 }')"
    fi
    [ "$actual" = "$sums" ] || paperclip_die "Node.js checksum mismatch"
    mkdir -p "$PERSONAL_DIR"
    tar -xzf "$tmp/$name" -C "$PERSONAL_DIR"
    rm -rf "$tmp" "$prefix"
    mv "$PERSONAL_DIR/node-v${PAPERCLIP_NODE_VERSION}-${os}-${arch}" "$prefix"
  fi
  PAPERCLIP_NODE="$prefix/bin/node"
  paperclip_node_is_supported "$PAPERCLIP_NODE" || paperclip_die "downloaded Node.js is older than 24.11.0"
}

ensure_pnpm_and_deps() {
  export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
  export PATH="$(dirname "$PAPERCLIP_NODE"):$PATH"
  # A set CI variable makes pnpm force a frozen lockfile even when we pass the opposite flag.
  unset CI || true
  cd "$CHECKOUT"
  if ! corepack prepare "pnpm@${PAPERCLIP_PNPM_VERSION}" --activate; then
    "$PAPERCLIP_NODE" "$(dirname "$PAPERCLIP_NODE")/npm" install -g "pnpm@${PAPERCLIP_PNPM_VERSION}"
  fi
  if corepack pnpm --version >/dev/null 2>&1; then
    pnpm_cmd="corepack pnpm"
  else
    pnpm_cmd="pnpm"
  fi
  # pnpm_cmd is either "corepack pnpm" or "pnpm".
  # shellcheck disable=SC2086
  if ! $pnpm_cmd install --frozen-lockfile; then
    paperclip_log "pnpm-lock.yaml does not match the manifests. Installing without a frozen lockfile."
    lock_dirty=0
    if [ -n "$(git -C "$CHECKOUT" status --porcelain -- pnpm-lock.yaml)" ]; then
      lock_dirty=1
    fi
    # shellcheck disable=SC2086
    $pnpm_cmd install --no-frozen-lockfile
    if [ "$lock_dirty" = "0" ]; then
      git -C "$CHECKOUT" checkout -- pnpm-lock.yaml
      paperclip_log "Restored pnpm-lock.yaml so a generated lockfile does not block the updater."
    fi
  fi
  "$PAPERCLIP_NODE" scripts/ensure-plugin-build-deps.mjs
  if [ "$FULL_BUILD" = "1" ]; then
    # shellcheck disable=SC2086
    $pnpm_cmd build
  fi
}

write_state() {
  umask 077
  cat >"$STATE_FILE" <<EOF
PAPERCLIP_CHECKOUT='$CHECKOUT'
PAPERCLIP_HOME='$HOME_DIR'
PAPERCLIP_PORT='$CHOSEN_PORT'
PAPERCLIP_UPDATE_BRANCH='$BRANCH'
PAPERCLIP_MODE='$MODE'
PAPERCLIP_NODE='${PAPERCLIP_NODE:-}'
PAPERCLIP_REPO_URL='$REPO_URL'
EOF
  chmod 600 "$STATE_FILE"
}

write_run_scripts() {
  local run_script="$PERSONAL_DIR/bin/run-source.sh"
  local supervise="$PERSONAL_DIR/bin/supervise.sh"
  local update_link="$PERSONAL_DIR/bin/update.sh"
  local tsx=""
  local candidate
  for candidate in \
    "$CHECKOUT/cli/node_modules/tsx/dist/cli.mjs" \
    "$CHECKOUT/node_modules/tsx/dist/cli.mjs"
  do
    if [ -f "$candidate" ]; then
      tsx="$candidate"
      break
    fi
  done
  [ -n "$tsx" ] || paperclip_die "tsx is not installed. Run pnpm install in $CHECKOUT."
  cat >"$run_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
set -a
. '$STATE_FILE'
set +a
export PATH="\$(dirname "\$PAPERCLIP_NODE"):\$PATH"
export HOST=127.0.0.1
export PORT="\$PAPERCLIP_PORT"
export PAPERCLIP_HOME
export PAPERCLIP_CONFIG='$HOME_DIR/instances/default/config.json'
export PAPERCLIP_MIGRATION_AUTO_APPLY=true
export PAPERCLIP_MIGRATION_PROMPT=never
export PAPERCLIP_UI_DEV_MIDDLEWARE=true
export PAPERCLIP_NO_BROWSER=1
export PAPERCLIP_SERVICE_MANAGED=1
cd "\$PAPERCLIP_CHECKOUT"
echo \$\$ >'$PERSONAL_DIR/server.pid'
exec "\$PAPERCLIP_NODE" '$tsx' "\$PAPERCLIP_CHECKOUT/server/src/index.ts"
EOF
  cat >"$supervise" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo \$\$ >'$PERSONAL_DIR/supervise.pid'
while true; do
  '$run_script' >>'$PERSONAL_DIR/logs/service.log' 2>&1 || true
  sleep 5
done
EOF
  chmod 700 "$run_script" "$supervise"
  ln -sfn "$CHECKOUT/scripts/personal/update.sh" "$update_link"
}

install_systemd() {
  local unit_dir="${HOME}/.config/systemd/user"
  local run_script="$PERSONAL_DIR/bin/run-source.sh"
  local update_script="$PERSONAL_DIR/bin/update.sh"
  mkdir -p "$unit_dir"
  cat >"$unit_dir/$PAPERCLIP_SYSTEMD_SERVICE" <<EOF
[Unit]
Description=Paperclip personal fork
After=network-online.target

[Service]
Type=simple
ExecStart=$run_script
Restart=always
RestartSec=5
TimeoutStopSec=90
WorkingDirectory=$CHECKOUT

[Install]
WantedBy=default.target
EOF
  cat >"$unit_dir/paperclip-personal-update.service" <<EOF
[Unit]
Description=Paperclip personal fork update check

[Service]
Type=oneshot
ExecStart=$update_script --scheduled
EOF
  cat >"$unit_dir/$PAPERCLIP_SYSTEMD_TIMER" <<EOF
[Unit]
Description=Wake the Paperclip updater once a day. The script applies changes every 10 days.

[Timer]
OnCalendar=*-*-* 04:17:00
Persistent=true
AccuracySec=1h

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now "$PAPERCLIP_SYSTEMD_SERVICE"
  systemctl --user enable --now "$PAPERCLIP_SYSTEMD_TIMER"
  if paperclip_have loginctl; then
    loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || paperclip_log "Could not enable lingering. The service stops at logout until lingering is enabled."
  fi
}

install_launchd() {
  local agent_dir="${HOME}/Library/LaunchAgents"
  local run_script="$PERSONAL_DIR/bin/run-source.sh"
  local update_script="$PERSONAL_DIR/bin/update.sh"
  mkdir -p "$agent_dir" "$PERSONAL_DIR/logs"
  cat >"$agent_dir/${PAPERCLIP_LAUNCHD_LABEL}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${PAPERCLIP_LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${run_script}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>${PERSONAL_DIR}/logs/service.log</string>
  <key>StandardErrorPath</key><string>${PERSONAL_DIR}/logs/service.log</string>
</dict>
</plist>
EOF
  cat >"$agent_dir/${PAPERCLIP_LAUNCHD_UPDATE_LABEL}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${PAPERCLIP_LAUNCHD_UPDATE_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${update_script}</string>
    <string>--scheduled</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>4</integer>
    <key>Minute</key><integer>17</integer>
  </dict>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$PAPERCLIP_LAUNCHD_LABEL" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)/$PAPERCLIP_LAUNCHD_UPDATE_LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$agent_dir/${PAPERCLIP_LAUNCHD_LABEL}.plist"
  launchctl bootstrap "gui/$(id -u)" "$agent_dir/${PAPERCLIP_LAUNCHD_UPDATE_LABEL}.plist"
  launchctl enable "gui/$(id -u)/$PAPERCLIP_LAUNCHD_LABEL" || true
  launchctl enable "gui/$(id -u)/$PAPERCLIP_LAUNCHD_UPDATE_LABEL" || true
}

install_cron_block() {
  local include_reboot="$1"
  local update_script="$PERSONAL_DIR/bin/update.sh"
  local supervise="$PERSONAL_DIR/bin/supervise.sh"
  local existing filtered block
  paperclip_have crontab || {
    paperclip_log "crontab is not available. The updater was not scheduled."
    return 0
  }
  existing="$(crontab -l 2>/dev/null || true)"
  filtered="$(printf '%s\n' "$existing" | paperclip_filter_cron_block)"
  block="$(paperclip_cron_block "$update_script" "$supervise" "$include_reboot")"
  {
    printf '%s\n' "$filtered" | sed '/^$/d'
    printf '\n%s\n' "$block"
  } | crontab -
  paperclip_log "Installed a daily cron wake. The updater applies changes every 10 days."
}

start_supervisor() {
  local supervise="$PERSONAL_DIR/bin/supervise.sh"
  if curl -fsS "http://127.0.0.1:${CHOSEN_PORT}/api/health" >/dev/null 2>&1; then
    paperclip_log "Paperclip is already answering on port $CHOSEN_PORT. Leaving it running."
    return
  fi
  if [ -f "$PERSONAL_DIR/supervise.pid" ]; then
    local old
    old="$(cat "$PERSONAL_DIR/supervise.pid" 2>/dev/null || true)"
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
      paperclip_log "Supervisor already running (pid $old)"
      return
    fi
  fi
  nohup "$supervise" >/dev/null 2>&1 &
  paperclip_log "Started direct supervisor because systemd and launchd are not available"
}

wait_for_health() {
  local url="http://127.0.0.1:${CHOSEN_PORT}/api/health"
  local attempt
  paperclip_have curl || paperclip_die "curl is required to check $url"
  attempt=0
  while [ "$attempt" -lt 180 ]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      paperclip_log "Paperclip is up at $url"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  paperclip_die "Paperclip did not answer $url. See $PERSONAL_DIR/logs/service.log"
}

install_docker() {
  paperclip_have docker || paperclip_die "Docker is required for --docker"
  docker compose version >/dev/null 2>&1 || paperclip_die "docker compose is required for --docker"
  export PAPERCLIP_CHOSEN_PORT="$CHOSEN_PORT"
  paperclip_write_docker_env_if_missing
  mkdir -p "$HOME_DIR/docker-data"
  export PAPERCLIP_PUBLISH_PORT="$CHOSEN_PORT"
  export PAPERCLIP_DOCKER_ENV_FILE="$PERSONAL_DIR/docker.env"
  export PAPERCLIP_DOCKER_DATA_DIR="$HOME_DIR/docker-data"
  docker compose -f "$CHECKOUT/scripts/personal/docker-compose.yml" up -d --build
  docker update \
    --memory="$PAPERCLIP_DOCKER_MEMORY" \
    --memory-swap="$PAPERCLIP_DOCKER_MEMORY" \
    --memory-reservation="$PAPERCLIP_DOCKER_MEMORY_RESERVATION" \
    "$PAPERCLIP_DOCKER_CONTAINER"
  paperclip_log "Docker memory cap is $PAPERCLIP_DOCKER_MEMORY (reservation $PAPERCLIP_DOCKER_MEMORY_RESERVATION)"
}

ensure_checkout

if [ "$MODE" = "docker" ]; then
  PAPERCLIP_NODE="${PAPERCLIP_NODE:-}"
  write_state
  export PAPERCLIP_CHOSEN_PORT="$CHOSEN_PORT"
  paperclip_write_agent_snippets_if_missing
  ln -sfn "$CHECKOUT/scripts/personal/update.sh" "$PERSONAL_DIR/bin/update.sh"
  install_docker
  if paperclip_user_systemd_works || paperclip_launchd_works || paperclip_have crontab; then
    install_cron_block 0
  fi
  date +%s >"$(paperclip_update_stamp_file)"
  wait_for_health
else
  ensure_node
  ensure_pnpm_and_deps
  export PAPERCLIP_CHOSEN_PORT="$CHOSEN_PORT"
  if [ ! -f "$(paperclip_config_file)" ]; then
    export PAPERCLIP_CHOSEN_DB_PORT
    PAPERCLIP_CHOSEN_DB_PORT="$(paperclip_choose_db_port)"
  fi
  paperclip_write_source_config_if_missing
  paperclip_write_secrets_if_missing
  paperclip_write_agent_snippets_if_missing
  write_state
  write_run_scripts
  if paperclip_user_systemd_works; then
    install_systemd
  elif paperclip_launchd_works; then
    install_launchd
  else
    install_cron_block 1
    start_supervisor
  fi
  date +%s >"$(paperclip_update_stamp_file)"
  wait_for_health
fi

paperclip_log "Manual update: bash $CHECKOUT/scripts/update.sh"
paperclip_log "Snippets: $(paperclip_agent_snippets_dir)"
paperclip_log "Setup guide: $CHECKOUT/PERSONAL_SETUP.md"
