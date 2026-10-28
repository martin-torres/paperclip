# Personal setup

This fork of Paperclip is the copy that runs on the owner's machines.
GitHub `master` on `martin-torres/paperclip` is the source of truth for those personal changes.
The upstream project remains `paperclipai/paperclip`.

The published `scripts/install.sh` installer (the one served by paperclip.ing) is unchanged.
Personal installs use `scripts/personal/install.sh`.
From a checkout, `bash scripts/install.sh --personal` and `bash scripts/install.sh --docker` dispatch to that script.

## One-line install

Linux always-on box and the MacBook:

```sh
curl -fsSL https://raw.githubusercontent.com/martin-torres/paperclip/master/scripts/personal/install.sh | bash
```

Ubuntu VPS (Docker is already installed, Node 24 may also be installed):

```sh
curl -fsSL https://raw.githubusercontent.com/martin-torres/paperclip/master/scripts/personal/install.sh | bash -s -- --docker
```

From a checkout you already have:

```sh
bash scripts/personal/install.sh
bash scripts/personal/install.sh --docker
```

The host install listens on `127.0.0.1` port **9000**.
If 9000 is taken on the first run, the installer uses **18790**.
Set `PAPERCLIP_PORT` before the first run to choose another port.
Open `http://127.0.0.1:9000`.

On the VPS, reach the board through an SSH tunnel:

```sh
ssh -L 9000:127.0.0.1:9000 user@your-vps
```

Then open `http://127.0.0.1:9000` on the machine that opened the tunnel.

## What each machine runs

| Machine | Command | How it stays up | Memory |
| --- | --- | --- | --- |
| Always-on Linux box | the host one-liner | systemd user service. If systemd is absent, a supervisor process plus `@reboot` cron | host RAM |
| MacBook | the host one-liner | launchd agent `ing.paperclip.personal` | host RAM |
| Ubuntu VPS | the `--docker` one-liner | `restart: unless-stopped`, published only on `127.0.0.1` | hard cap `1g`, reservation `512m` |

The host service runs the checkout with Node.js 24.11 or newer.
When the shell's Node is older, the installer downloads Node.js 24.22.2 into `~/.paperclip/personal/`.
It does not replace a Node that is already new enough.

The VPS container listens on `0.0.0.0` inside the network namespace so Docker can forward the port.
The host publish address is `127.0.0.1`.
That install uses authenticated private mode, because a loopback-only process inside the container is not reachable through a published port.
Sign in through the SSH tunnel and claim the instance in the browser.
The host install uses `local_trusted` on `127.0.0.1`, which does not ask for a login.

The first Docker image build needs more RAM than the running cap.
On a 2 vCPU VPS, add swap before the first `--docker` install if the build is killed.
The running container is still limited to 1 GB (`PAPERCLIP_DOCKER_MEMORY`) with a 512 MB reservation (`PAPERCLIP_DOCKER_MEMORY_RESERVATION`).
Heavy agent CLIs belong on the always-on Linux box. The 1 GB cap is enough for the board and small local work, and it will kill a container that grows past it.

A second run keeps the existing config, `.env`, secrets key, database, Docker env file, and Docker data directory.
It does not switch a host install to Docker, or the reverse, unless you pass `--switch-mode`.

## Layout

```text
~/.paperclip/instances/default/     config, database, secrets, logs, uploads
~/.paperclip/personal/state.env     checkout path, port, mode
~/.paperclip/personal/logs/         service.log and update.log
~/.paperclip/personal/agent-access/ ready-to-paste harness snippets
~/.paperclip/personal/docker.env    VPS secrets (mode docker only)
~/.paperclip/docker-data/           VPS Paperclip home (mode docker only)
~/paperclip/                        checkout used by the one-line installer
```

`PAPERCLIP_HOME` changes the `~/.paperclip` prefix.
`PAPERCLIP_CHECKOUT` changes the git directory.
The one-line installer clones `https://github.com/martin-torres/paperclip.git` and checks out `master` when the checkout is missing.
It does not pull on later runs. Use the updater for that.

## Updates

The updater checks `origin/master`.
This repository's default branch is `master`. There is no `main` branch.

It applies a change only when all of these are true:

- the checkout is on `master`
- `git status` is clean (ignored files such as `node_modules` do not count)
- `origin/master` has new commits

It then fast-forwards, runs `pnpm install`, rebuilds the small set of packages the source server needs, and restarts.
If `pnpm-lock.yaml` is behind the manifests, the installer resolves dependencies and restores a previously clean lockfile so that drift does not block the next update.
Pending database migrations apply on restart (`PAPERCLIP_MIGRATION_AUTO_APPLY=true`).
The Docker updater rebuilds the image and restarts the same data volume.
A failed fast-forward does not reset the checkout.

The schedule wakes once a day at 04:17.
The script returns immediately until **10 days** have passed since the last successful check.
That interval is 864000 seconds. It is not a 10-minute cron.
A dirty tree is skipped and retried on the next daily wake.
An unchanged tree waits another 10 days.

Run this on a machine when you want the update now:

```sh
bash scripts/update.sh
```

Or, if you are not in the checkout:

```sh
~/.paperclip/personal/bin/update.sh
```

The log is `~/.paperclip/personal/logs/update.log`.

Push personal commits to `origin/master`.
The other machines pick them up at the next 10-day check, or when you run `bash scripts/update.sh` there.

## Sync with upstream

Add the upstream remote once, in the checkout:

```sh
git remote add upstream https://github.com/paperclipai/paperclip.git
git fetch upstream
git checkout master
git merge upstream/master
```

Resolve conflicts, test, and push to this fork:

```sh
git push origin master
```

Use merge. A rebase rewrites `master` after the other machines have pulled it.
The published installer at the top of `scripts/install.sh` should stay intact across that merge.
The personal dispatch is only the short block for `--personal` and `--docker`.

## Customize

Edit `~/.paperclip/instances/default/config.json` for the host install.
The port, embedded Postgres directory, and log directory are there.
After a port change, set the same port in `~/.paperclip/personal/state.env` and restart the service.
The installer will not write over that file again.

Secrets live in `~/.paperclip/instances/default/.env` and `secrets/master.key`.
On the VPS they live in `~/.paperclip/personal/docker.env`.
Do not commit those files.
A re-run adds a missing secret key and leaves existing values as they are.

To build the full production bundle, including the native runner, re-run with `--full-build`.
The default host service does not need that bundle. It runs the TypeScript server with the dev UI middleware.

Restart after a host config edit:

```sh
systemctl --user restart paperclip-personal.service
```

On a Mac:

```sh
launchctl kickstart -k "gui/$(id -u)/ing.paperclip.personal"
```

When systemd and launchd are both absent, the supervisor pid is `~/.paperclip/personal/supervise.pid`.
Stop that pid and run `~/.paperclip/personal/bin/supervise.sh` again.
On the VPS:

```sh
docker restart paperclip-personal
```

## Agent and harness access

The board is `http://127.0.0.1:9000` (or 18790 if that was the free port).
Create a company and hire agents in the UI. Paperclip wakes a hired agent and injects these variables for that run:

- `PAPERCLIP_API_URL`
- `PAPERCLIP_API_KEY` (a short-lived run token for local adapters)
- `PAPERCLIP_AGENT_ID`
- `PAPERCLIP_COMPANY_ID`
- `PAPERCLIP_RUN_ID`

Use these adapter types when you hire:

| Harness | Adapter | Notes |
| --- | --- | --- |
| Claude Code | `claude_local` | Paperclip starts the local `claude` CLI |
| Codex | `codex_local` | Paperclip starts the local `codex` CLI |
| Cursor | `cursor` | Local Cursor agent adapter |
| Hermes | `hermes_local` | Paperclip starts the Hermes CLI |
| Hermes Gateway | `hermes_gateway` | Hermes is already running. Default API port is 8642. See `doc/HERMES_GATEWAY_ONBOARDING.md` |
| OpenClaw | `openclaw_gateway` | OpenClaw gateway stays on its own port (often 18789). See `doc/OPENCLAW_ONBOARDING.md` |

Do not point OpenClaw or Hermes at port 9000. That port is Paperclip.
Point those products at Paperclip with the invite flow in the docs above, and set their gateway URL to the address Paperclip can reach.

After the agent exists, install its skill and print a shell snippet from the checkout:

```sh
node cli/node_modules/tsx/dist/cli.mjs cli/src/index.ts agent local-cli AGENT_ID_OR_NAME --company-id COMPANY_ID
```

That command creates an agent API key once, copies `skills/paperclip` into `~/.claude/skills`, `~/.codex/skills`, and `~/.kimi-code/skills`, and prints:

```sh
export PAPERCLIP_API_URL='http://127.0.0.1:9000'
export PAPERCLIP_COMPANY_ID='COMPANY_ID'
export PAPERCLIP_AGENT_ID='AGENT_ID'
export PAPERCLIP_API_KEY='AGENT_API_KEY'
```

Keep the key out of git and out of chat transcripts.
The same values are written, with placeholders, to `~/.paperclip/personal/agent-access/` on the first install. Later installs do not overwrite that directory.

CLI calls from the checkout:

```sh
node cli/node_modules/tsx/dist/cli.mjs cli/src/index.ts --api-base http://127.0.0.1:9000 --api-key "$PAPERCLIP_API_KEY" agent me
```

Board commands on a `local_trusted` host install can omit the key when you run them on that machine.
Use `npx paperclipai` for any argument that contains task text, comments, or other untrusted content. See `doc/CLI.md`.

### MCP clients

Stdio MCP, for Claude Code, Codex, Cursor, and other MCP clients. Merge this into the client's existing MCP config. Do not replace the whole file when other servers are already there.

```json
{
  "mcpServers": {
    "paperclip": {
      "command": "npx",
      "args": ["-y", "@paperclipai/mcp-server"],
      "env": {
        "PAPERCLIP_API_URL": "http://127.0.0.1:9000",
        "PAPERCLIP_API_KEY": "AGENT_API_KEY"
      }
    }
  }
}
```

Codex `~/.codex/config.toml` fragment (also written to `~/.paperclip/personal/agent-access/codex-mcp.toml`):

```toml
[mcp_servers.paperclip]
command = "npx"
args = ["-y", "@paperclipai/mcp-server"]

[mcp_servers.paperclip.env]
PAPERCLIP_API_URL = "http://127.0.0.1:9000"
PAPERCLIP_API_KEY = "AGENT_API_KEY"
```

Cursor uses the same JSON shape in `~/.cursor/mcp.json`.
Claude Code can use that JSON in its MCP settings, or the HTTP endpoint below.

The VPS (authenticated) can also use the public Paperclip MCP endpoint.
In the board, open Settings, Experimental, Assistant connections (MCP), and turn it on.
Localhost HTTP is accepted for that endpoint.

```sh
claude mcp add --transport http paperclip http://127.0.0.1:9000/mcp/paperclip
codex mcp add paperclip --url http://127.0.0.1:9000/mcp/paperclip
```

A headless client can use the device login from `doc/public-mcp.md`:

```sh
paperclipai mcp login --device --url http://127.0.0.1:9000/mcp/paperclip
paperclipai mcp proxy --url http://127.0.0.1:9000/mcp/paperclip
```

The host `local_trusted` install does not serve that public OAuth flow.
Use the stdio MCP server and an agent API key there.

## Backup

Stop the service so the database files are quiet, then copy the instance directory:

```sh
systemctl --user stop paperclip-personal.service
tar -C "$HOME/.paperclip" -czf "$HOME/paperclip-instance-backup.tgz" instances
systemctl --user start paperclip-personal.service
```

On the VPS, stop the container and copy both the data directory and the env file:

```sh
docker stop paperclip-personal
tar -C "$HOME/.paperclip" -czf "$HOME/paperclip-docker-backup.tgz" docker-data personal/docker.env
docker start paperclip-personal
```

`personal/docker.env` and `instances/default/.env` are required to read the copied database.
Without them, sessions and secrets do not match.

While the host server is running, `bash scripts/backup-db.sh` from the checkout writes a logical backup into the instance backup directory.
Stop-and-copy is the restore path to keep.

## Uninstall

This stops the service and removes the systemd unit, launchd agents, cron block, and supervisor.
It keeps the checkout and the database:

```sh
bash scripts/uninstall.sh
```

Delete the database and Docker data as well:

```sh
bash scripts/uninstall.sh --purge-data
```

Also delete the one-line checkout at `~/paperclip` (a checkout anywhere else is left alone):

```sh
bash scripts/uninstall.sh --purge-data --remove-checkout
```

## Checks

```sh
curl -fsS http://127.0.0.1:9000/api/health
bash scripts/personal/personal-setup.test.sh
bash scripts/update.sh
```

Service logs:

```sh
tail -f ~/.paperclip/personal/logs/service.log
tail -f ~/.paperclip/personal/logs/update.log
```
