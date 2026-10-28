#!/usr/bin/env bash
# Shared helpers for the personal fork installer.
# This file is safe to source. It does not start a service.

# Ten days. The scheduled updater uses this interval.
# 10 * 24 * 60 * 60 = 864000 seconds.
PAPERCLIP_UPDATE_INTERVAL_SECONDS="${PAPERCLIP_UPDATE_INTERVAL_SECONDS:-864000}"
PAPERCLIP_UPDATE_BRANCH_DEFAULT="master"
PAPERCLIP_DEFAULT_PORT="9000"
PAPERCLIP_FALLBACK_PORT="18790"
PAPERCLIP_DEFAULT_REPO_URL="https://github.com/martin-torres/paperclip.git"
PAPERCLIP_UPSTREAM_URL="https://github.com/paperclipai/paperclip.git"
PAPERCLIP_MIN_NODE_MAJOR=24
PAPERCLIP_MIN_NODE_MINOR=11
PAPERCLIP_MIN_NODE_PATCH=0
PAPERCLIP_NODE_VERSION="${PAPERCLIP_NODE_VERSION:-24.22.2}"
PAPERCLIP_PNPM_VERSION="9.15.4"
PAPERCLIP_DOCKER_MEMORY="${PAPERCLIP_DOCKER_MEMORY:-1g}"
PAPERCLIP_DOCKER_MEMORY_RESERVATION="${PAPERCLIP_DOCKER_MEMORY_RESERVATION:-512m}"
PAPERCLIP_CRON_MARKER_BEGIN="# BEGIN paperclip-personal"
PAPERCLIP_CRON_MARKER_END="# END paperclip-personal"
PAPERCLIP_SYSTEMD_SERVICE="paperclip-personal.service"
PAPERCLIP_SYSTEMD_TIMER="paperclip-personal-update.timer"
PAPERCLIP_LAUNCHD_LABEL="ing.paperclip.personal"
PAPERCLIP_LAUNCHD_UPDATE_LABEL="ing.paperclip.personal.update"
PAPERCLIP_DOCKER_CONTAINER="paperclip-personal"

paperclip_log() {
  printf '[paperclip-personal] %s\n' "$*"
}

paperclip_die() {
  printf '[paperclip-personal] error: %s\n' "$*" >&2
  exit 1
}

paperclip_have() {
  command -v "$1" >/dev/null 2>&1
}

paperclip_absdir() {
  (cd "$1" && pwd)
}

paperclip_home_dir() {
  if [ -n "${PAPERCLIP_HOME:-}" ]; then
    printf '%s\n' "$PAPERCLIP_HOME"
    return
  fi
  printf '%s\n' "${HOME:?HOME is required}/.paperclip"
}

paperclip_personal_dir() {
  printf '%s\n' "$(paperclip_home_dir)/personal"
}

paperclip_state_file() {
  printf '%s\n' "$(paperclip_personal_dir)/state.env"
}

paperclip_state_get() {
  local key="$1"
  local file
  file="$(paperclip_state_file)"
  [ -f "$file" ] || return 0
  sed -n "s/^${key}=//p" "$file" | tail -n 1 | tr -d "'\""
}

paperclip_infer_home_from_script() {
  local script="$1"
  local dir
  if [ -n "${PAPERCLIP_HOME:-}" ]; then
    return 0
  fi
  dir="$(cd "$(dirname "$script")" && pwd)"
  if [ -f "$dir/../state.env" ]; then
    PAPERCLIP_HOME="$(cd "$dir/../.." && pwd)"
    export PAPERCLIP_HOME
  fi
}

paperclip_instance_dir() {
  printf '%s\n' "$(paperclip_home_dir)/instances/default"
}

paperclip_config_file() {
  printf '%s\n' "$(paperclip_instance_dir)/config.json"
}

paperclip_env_file() {
  printf '%s\n' "$(paperclip_instance_dir)/.env"
}

paperclip_update_stamp_file() {
  printf '%s\n' "$(paperclip_personal_dir)/last-successful-update-check"
}

paperclip_sanitize_git_url() {
  printf '%s\n' "$1" | sed -E 's#(://)[^/@]*@#\1#'
}

paperclip_reject_odd_path() {
  local label="$1"
  local value="$2"
  case "$value" in
    *\"*|*\\*|*' '*)
      paperclip_die "$label contains a space, quote, or backslash: $value"
      ;;
  esac
}

paperclip_node_is_supported() {
  local bin="${1:-node}"
  local version major minor patch
  "$bin" --version >/dev/null 2>&1 || return 1
  version="$("$bin" --version 2>/dev/null || true)"
  version="${version#v}"
  major="${version%%.*}"
  minor="${version#*.}"
  minor="${minor%%.*}"
  patch="${version##*.}"
  patch="${patch%%-*}"
  case "$major$minor$patch" in
    *[!0-9]*) return 1 ;;
  esac
  if [ "$major" -gt "$PAPERCLIP_MIN_NODE_MAJOR" ]; then
    return 0
  fi
  if [ "$major" -lt "$PAPERCLIP_MIN_NODE_MAJOR" ]; then
    return 1
  fi
  if [ "$minor" -gt "$PAPERCLIP_MIN_NODE_MINOR" ]; then
    return 0
  fi
  if [ "$minor" -lt "$PAPERCLIP_MIN_NODE_MINOR" ]; then
    return 1
  fi
  [ "$patch" -ge "$PAPERCLIP_MIN_NODE_PATCH" ]
}

paperclip_port_is_free() {
  local port="$1"
  if paperclip_have node; then
    node -e 'const n=require("net"); const p=Number(process.argv[1]); const s=n.createServer(); s.once("error",()=>process.exit(1)); s.listen({host:"127.0.0.1",port:p},()=>s.close(()=>process.exit(0)));' "$port"
    return $?
  fi
  if paperclip_have python3; then
    python3 - "$port" <<'PY'
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
    return $?
  fi
  paperclip_die "node or python3 is required to test whether port $port is free"
}

paperclip_choose_port() {
  if [ -n "${PAPERCLIP_PORT:-}" ]; then
    paperclip_port_is_free "$PAPERCLIP_PORT" || paperclip_die "PAPERCLIP_PORT=$PAPERCLIP_PORT is already in use"
    printf '%s\n' "$PAPERCLIP_PORT"
    return
  fi
  if paperclip_port_is_free "$PAPERCLIP_DEFAULT_PORT"; then
    printf '%s\n' "$PAPERCLIP_DEFAULT_PORT"
    return
  fi
  if paperclip_port_is_free "$PAPERCLIP_FALLBACK_PORT"; then
    printf '%s\n' "$PAPERCLIP_FALLBACK_PORT"
    return
  fi
  paperclip_die "ports $PAPERCLIP_DEFAULT_PORT and $PAPERCLIP_FALLBACK_PORT are both in use. Set PAPERCLIP_PORT."
}

paperclip_choose_db_port() {
  local candidate=54329
  local end=54339
  while [ "$candidate" -le "$end" ]; do
    if paperclip_port_is_free "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
    candidate=$((candidate + 1))
  done
  paperclip_die "no free embedded Postgres port from 54329 through 54339"
}

paperclip_random_hex() {
  if paperclip_have openssl; then
    openssl rand -hex 32
    return
  fi
  node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))'
}

paperclip_random_base64() {
  if paperclip_have openssl; then
    openssl rand -base64 32
    return
  fi
  node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("base64"))'
}

paperclip_ensure_env_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  if [ -f "$file" ] && grep -q "^${key}=" "$file"; then
    return 0
  fi
  if [ ! -f "$file" ]; then
    mkdir -p "$(dirname "$file")"
    umask 077
    printf '%s\n' "# Paperclip environment variables" "# Generated by scripts/personal/install.sh. Existing values are kept on re-run." >"$file"
  fi
  printf '%s=%s\n' "$key" "$value" >>"$file"
  chmod 600 "$file"
}

paperclip_write_source_config_if_missing() {
  local config port db_port home instance
  config="$(paperclip_config_file)"
  if [ -f "$config" ]; then
    paperclip_log "Keeping existing config at $config"
    return 0
  fi
  home="$(paperclip_home_dir)"
  instance="$(paperclip_instance_dir)"
  port="${PAPERCLIP_CHOSEN_PORT:?PAPERCLIP_CHOSEN_PORT is required}"
  db_port="${PAPERCLIP_CHOSEN_DB_PORT:?PAPERCLIP_CHOSEN_DB_PORT is required}"
  paperclip_reject_odd_path "PAPERCLIP_HOME" "$home"
  mkdir -p "$instance/db" "$instance/logs" "$instance/data/backups" "$instance/data/storage" "$instance/secrets"
  umask 077
  cat >"$config" <<EOF
{
  "\$meta": {
    "version": 1,
    "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "source": "onboard"
  },
  "database": {
    "mode": "embedded-postgres",
    "embeddedPostgresDataDir": "$instance/db",
    "embeddedPostgresPort": $db_port,
    "backup": {
      "enabled": true,
      "intervalMinutes": 60,
      "retentionDays": 30,
      "dir": "$instance/data/backups"
    }
  },
  "logging": {
    "mode": "file",
    "logDir": "$instance/logs"
  },
  "server": {
    "deploymentMode": "local_trusted",
    "exposure": "private",
    "bind": "loopback",
    "host": "127.0.0.1",
    "port": $port,
    "allowedHostnames": [],
    "serveUi": true
  },
  "auth": {
    "baseUrlMode": "auto",
    "disableSignUp": false
  },
  "telemetry": {
    "enabled": true
  },
  "storage": {
    "provider": "local_disk",
    "localDisk": {
      "baseDir": "$instance/data/storage"
    },
    "s3": {
      "bucket": "paperclip",
      "region": "us-east-1",
      "prefix": "",
      "forcePathStyle": false
    }
  },
  "secrets": {
    "provider": "local_encrypted",
    "strictMode": false,
    "localEncrypted": {
      "keyFilePath": "$instance/secrets/master.key"
    }
  }
}
EOF
  chmod 600 "$config"
  paperclip_log "Wrote new config at $config"
}

paperclip_write_secrets_if_missing() {
  local instance key_file env_file
  instance="$(paperclip_instance_dir)"
  env_file="$(paperclip_env_file)"
  key_file="$instance/secrets/master.key"
  mkdir -p "$instance/secrets"
  if [ ! -f "$key_file" ]; then
    umask 077
    paperclip_random_base64 >"$key_file"
    chmod 600 "$key_file"
    paperclip_log "Wrote new secrets master key at $key_file"
  else
    paperclip_log "Keeping existing secrets master key at $key_file"
  fi
  paperclip_ensure_env_key "$env_file" "PAPERCLIP_AGENT_JWT_SECRET" "$(paperclip_random_hex)"
  paperclip_ensure_env_key "$env_file" "PAPERCLIP_TOOL_ACTION_SIGNING_SECRET" "$(paperclip_random_hex)"
}

paperclip_write_docker_env_if_missing() {
  local file port
  file="$(paperclip_personal_dir)/docker.env"
  port="${PAPERCLIP_CHOSEN_PORT:?PAPERCLIP_CHOSEN_PORT is required}"
  if [ -f "$file" ]; then
    paperclip_log "Keeping existing Docker env at $file"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  umask 077
  cat >"$file" <<EOF
HOST=0.0.0.0
PORT=3100
PAPERCLIP_HOME=/paperclip
PAPERCLIP_INSTANCE_ID=default
PAPERCLIP_CONFIG=/paperclip/instances/default/config.json
PAPERCLIP_DEPLOYMENT_MODE=authenticated
PAPERCLIP_DEPLOYMENT_EXPOSURE=private
PAPERCLIP_PUBLIC_URL=http://127.0.0.1:${port}
SERVE_UI=true
PAPERCLIP_MIGRATION_AUTO_APPLY=true
PAPERCLIP_MIGRATION_PROMPT=never
BETTER_AUTH_SECRET=$(paperclip_random_hex)
PAPERCLIP_TOOL_ACTION_SIGNING_SECRET=$(paperclip_random_hex)
PAPERCLIP_AGENT_JWT_SECRET=$(paperclip_random_hex)
EOF
  chmod 600 "$file"
  paperclip_log "Wrote new Docker env at $file"
}

paperclip_agent_snippets_dir() {
  printf '%s\n' "$(paperclip_personal_dir)/agent-access"
}

paperclip_write_agent_snippets_if_missing() {
  local dir port url
  dir="$(paperclip_agent_snippets_dir)"
  port="${PAPERCLIP_CHOSEN_PORT:?PAPERCLIP_CHOSEN_PORT is required}"
  url="http://127.0.0.1:${port}"
  mkdir -p "$dir"
  if [ ! -f "$dir/mcp.json" ]; then
    cat >"$dir/mcp.json" <<EOF
{
  "mcpServers": {
    "paperclip": {
      "command": "npx",
      "args": ["-y", "@paperclipai/mcp-server"],
      "env": {
        "PAPERCLIP_API_URL": "${url}",
        "PAPERCLIP_API_KEY": "PASTE_AGENT_OR_BOARD_API_KEY"
      }
    }
  }
}
EOF
  fi
  if [ ! -f "$dir/codex-mcp.toml" ]; then
    cat >"$dir/codex-mcp.toml" <<EOF
[mcp_servers.paperclip]
command = "npx"
args = ["-y", "@paperclipai/mcp-server"]

[mcp_servers.paperclip.env]
PAPERCLIP_API_URL = "${url}"
PAPERCLIP_API_KEY = "PASTE_AGENT_OR_BOARD_API_KEY"
EOF
  fi
  if [ ! -f "$dir/env.example.sh" ]; then
    cat >"$dir/env.example.sh" <<EOF
export PAPERCLIP_API_URL='${url}'
export PAPERCLIP_COMPANY_ID='PASTE_COMPANY_ID'
export PAPERCLIP_AGENT_ID='PASTE_AGENT_ID'
export PAPERCLIP_API_KEY='PASTE_AGENT_API_KEY'
EOF
    chmod 600 "$dir/env.example.sh"
  fi
  if [ ! -f "$dir/README.md" ]; then
    cat >"$dir/README.md" <<EOF
# Agent access snippets for ${url}

These files were created once. A later install does not overwrite them.
Replace the PASTE_ placeholders after you create an agent API key.
See PERSONAL_SETUP.md in the checkout for Claude Code, Codex, Cursor,
OpenClaw, Hermes, and the public MCP endpoint.
EOF
  fi
}

paperclip_update_cron_line() {
  local update_script="$1"
  printf '%s\n' "17 4 * * * $update_script --scheduled"
}

paperclip_cron_block() {
  local update_script="$1"
  local supervise_script="$2"
  local include_reboot="$3"
  printf '%s\n' "$PAPERCLIP_CRON_MARKER_BEGIN"
  printf '%s\n' "# Daily wake. The updater applies origin changes only after 10 days."
  paperclip_update_cron_line "$update_script"
  if [ "$include_reboot" = "1" ]; then
    printf '%s\n' "@reboot $supervise_script"
  fi
  printf '%s\n' "$PAPERCLIP_CRON_MARKER_END"
}

paperclip_filter_cron_block() {
  awk -v begin="$PAPERCLIP_CRON_MARKER_BEGIN" -v end="$PAPERCLIP_CRON_MARKER_END" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    skip != 1 { print }
  '
}

paperclip_git_plan() {
  local checkout="$1"
  local branch="$2"
  local current local_rev remote_rev
  if [ -n "$(git -C "$checkout" status --porcelain)" ]; then
    printf 'dirty\n'
    return 0
  fi
  current="$(git -C "$checkout" rev-parse --abbrev-ref HEAD)"
  if [ "$current" != "$branch" ]; then
    printf 'wrong-branch\n'
    return 0
  fi
  if [ "${PAPERCLIP_UPDATE_SKIP_FETCH:-}" != "1" ]; then
    git -C "$checkout" fetch origin "$branch"
  fi
  local_rev="$(git -C "$checkout" rev-parse HEAD)"
  remote_rev="$(git -C "$checkout" rev-parse "origin/$branch")"
  if [ "$local_rev" = "$remote_rev" ]; then
    printf 'unchanged\n'
    return 0
  fi
  printf 'update\n'
}

paperclip_update_is_due() {
  local stamp="$1"
  local now last elapsed minimum
  minimum="$PAPERCLIP_UPDATE_INTERVAL_SECONDS"
  case "$minimum" in
    ''|*[!0-9]*) paperclip_die "PAPERCLIP_UPDATE_INTERVAL_SECONDS must be a positive number of seconds" ;;
  esac
  if [ "$minimum" -lt 86400 ] && [ "${PAPERCLIP_UPDATE_INTERVAL_SECONDS_UNSAFE:-}" != "1" ]; then
    paperclip_die "Refusing an update interval under 1 day. The schedule is 10 days."
  fi
  if [ ! -f "$stamp" ]; then
    return 0
  fi
  now="$(date +%s)"
  last="$(tr -cd '0-9' <"$stamp")"
  [ -n "$last" ] || return 0
  elapsed=$((now - last))
  [ "$elapsed" -ge "$minimum" ]
}

paperclip_user_systemd_works() {
  paperclip_have systemctl || return 1
  systemctl --user show-environment >/dev/null 2>&1
}

paperclip_launchd_works() {
  [ "$(uname -s 2>/dev/null || true)" = "Darwin" ] && paperclip_have launchctl
}
