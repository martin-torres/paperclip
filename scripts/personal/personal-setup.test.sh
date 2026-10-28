#!/usr/bin/env bash
# Hermetic checks for the personal installer. This does not build Paperclip.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib.sh
. "$ROOT/scripts/personal/lib.sh"

failures=0

pass() {
  printf 'ok %s\n' "$1"
}

fail() {
  printf 'not ok %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_eq() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label (got $actual, expected $expected)"
  fi
}

if [ "$PAPERCLIP_UPDATE_INTERVAL_SECONDS" -eq 864000 ]; then
  pass "interval is 10 days in seconds"
else
  fail "interval is 10 days in seconds"
fi

cron_line="$(paperclip_update_cron_line /tmp/paperclip-update.sh)"
assert_eq "cron wakes once a day" "$cron_line" "17 4 * * * /tmp/paperclip-update.sh --scheduled"

block="$(paperclip_cron_block /tmp/paperclip-update.sh /tmp/supervise.sh 1)"
printf '%s\n' "$block" | grep -q '^17 4 \* \* \* ' && pass "cron block uses a daily schedule" || fail "cron block uses a daily schedule"
printf '%s\n' "$block" | grep -q '@reboot /tmp/supervise.sh' && pass "direct-start fallback is an @reboot line" || fail "direct-start fallback is an @reboot line"
if printf '%s\n' "$block" | grep -q '\*/10 \* \* \* \*'; then
  fail "cron block must not use a 10 minute schedule"
else
  pass "cron block must not use a 10 minute schedule"
fi

if grep -n -E '(^|[^0-9])\*/10 \* \* \* \*' \
  "$ROOT/scripts/personal/lib.sh" \
  "$ROOT/scripts/personal/install.sh" \
  "$ROOT/scripts/personal/update.sh" \
  "$ROOT/scripts/personal/uninstall.sh" \
  "$ROOT/scripts/update.sh" \
  "$ROOT/scripts/uninstall.sh" \
  "$ROOT/scripts/personal/docker-compose.yml" >/dev/null; then
  fail "source contains a 10 minute cron expression"
else
  pass "source contains no 10 minute cron expression"
fi

filtered="$(printf '%s\n' "keep-me" "$block" "after" | paperclip_filter_cron_block)"
assert_eq "cron filter removes the personal block" "$filtered" "$(printf '%s\n' "keep-me" "after")"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/paperclip-personal-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export PAPERCLIP_HOME="$tmp/home"
export PAPERCLIP_CHOSEN_PORT=9000
export PAPERCLIP_CHOSEN_DB_PORT=54329

paperclip_write_source_config_if_missing
paperclip_write_secrets_if_missing
cp "$(paperclip_config_file)" "$tmp/config.copy"
cp "$(paperclip_env_file)" "$tmp/env.copy"
cp "$(paperclip_instance_dir)/secrets/master.key" "$tmp/key.copy"
paperclip_write_source_config_if_missing
paperclip_write_secrets_if_missing
PAPERCLIP_CHOSEN_PORT=18790 paperclip_write_source_config_if_missing
if cmp -s "$(paperclip_config_file)" "$tmp/config.copy"; then
  pass "config file was not regenerated"
else
  fail "config file was not regenerated"
fi
if cmp -s "$(paperclip_env_file)" "$tmp/env.copy"; then
  pass "env secrets were not regenerated"
else
  fail "env secrets were not regenerated"
fi
if cmp -s "$(paperclip_instance_dir)/secrets/master.key" "$tmp/key.copy"; then
  pass "master key was not regenerated"
else
  fail "master key was not regenerated"
fi

stamp="$tmp/stamp"
date +%s >"$stamp"
if paperclip_update_is_due "$stamp"; then
  fail "a fresh stamp is not due"
else
  pass "a fresh stamp is not due"
fi
printf '%s\n' "$(( $(date +%s) - 864000 ))" >"$stamp"
if paperclip_update_is_due "$stamp"; then
  pass "a 10 day old stamp is due"
else
  fail "a 10 day old stamp is due"
fi

if (PAPERCLIP_UPDATE_INTERVAL_SECONDS=600 paperclip_update_is_due "$tmp/missing-stamp") >/dev/null 2>"$tmp/interval.err"; then
  fail "short interval is refused"
else
  pass "short interval is refused"
fi
grep -q "10 days" "$tmp/interval.err" && pass "short interval names 10 days" || fail "short interval names 10 days"

export GIT_AUTHOR_NAME="Paperclip Test"
export GIT_AUTHOR_EMAIL="paperclip-test@example.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
git init -b master "$tmp/origin" >/dev/null
git -C "$tmp/origin" config user.email "$GIT_AUTHOR_EMAIL"
git -C "$tmp/origin" config user.name "$GIT_AUTHOR_NAME"
echo one >"$tmp/origin/README"
git -C "$tmp/origin" add README
git -C "$tmp/origin" commit -m one >/dev/null
git clone "$tmp/origin" "$tmp/checkout" >/dev/null
mkdir -p "$PAPERCLIP_HOME/personal/logs"
cat >"$PAPERCLIP_HOME/personal/state.env" <<EOF
PAPERCLIP_CHECKOUT='$tmp/checkout'
PAPERCLIP_HOME='$PAPERCLIP_HOME'
PAPERCLIP_PORT='9000'
PAPERCLIP_UPDATE_BRANCH='master'
PAPERCLIP_MODE='source'
PAPERCLIP_NODE='/usr/bin/false'
PAPERCLIP_REPO_URL='https://example.invalid/paperclip.git'
EOF
export PAPERCLIP_UPDATE_REBUILD_CMD="touch '$tmp/rebuilt'"
export PAPERCLIP_UPDATE_RESTART_CMD="touch '$tmp/restarted'"

bash "$ROOT/scripts/personal/update.sh" >"$tmp/update-unchanged.out"
grep -q "plan=unchanged" "$tmp/update-unchanged.out" && pass "clean matching tree does not rebuild" || fail "clean matching tree does not rebuild"
[ ! -f "$tmp/rebuilt" ] && pass "unchanged update did not rebuild" || fail "unchanged update did not rebuild"

echo two >>"$tmp/origin/README"
git -C "$tmp/origin" add README
git -C "$tmp/origin" commit -m two >/dev/null
bash "$ROOT/scripts/personal/update.sh" >"$tmp/update-changed.out"
grep -q "plan=update" "$tmp/update-changed.out" && pass "clean changed tree updates" || fail "clean changed tree updates"
[ -f "$tmp/rebuilt" ] && pass "update ran the rebuild hook" || fail "update ran the rebuild hook"
[ -f "$tmp/restarted" ] && pass "update ran the restart hook" || fail "update ran the restart hook"
assert_eq "checkout fast-forwarded" "$(git -C "$tmp/checkout" rev-parse HEAD)" "$(git -C "$tmp/origin" rev-parse HEAD)"

echo dirty >"$tmp/checkout/local.txt"
echo three >>"$tmp/origin/README"
git -C "$tmp/origin" add README
git -C "$tmp/origin" commit -m three >/dev/null
rm -f "$tmp/rebuilt"
bash "$ROOT/scripts/personal/update.sh" >"$tmp/update-dirty.out"
grep -q "plan=dirty" "$tmp/update-dirty.out" && pass "dirty tree is skipped" || fail "dirty tree is skipped"
[ ! -f "$tmp/rebuilt" ] && pass "dirty tree did not rebuild" || fail "dirty tree did not rebuild"
if [ "$(git -C "$tmp/checkout" rev-parse HEAD)" = "$(git -C "$tmp/origin" rev-parse HEAD)" ]; then
  fail "dirty tree was pulled"
else
  pass "dirty tree was not pulled"
fi

date +%s >"$(paperclip_update_stamp_file)"
bash "$ROOT/scripts/personal/update.sh" --scheduled >"$tmp/update-scheduled.out"
grep -q "not due" "$tmp/update-scheduled.out" && pass "scheduled run waits 10 days" || fail "scheduled run waits 10 days"

out="$(PAPERCLIP_HOME="$tmp/dry" bash "$ROOT/scripts/personal/install.sh" --dry-run)"
printf '%s\n' "$out" | grep -q 'bind=127.0.0.1' && pass "dry-run binds localhost" || fail "dry-run binds localhost"
printf '%s\n' "$out" | grep -q 'port=9000' && pass "dry-run uses port 9000" || fail "dry-run uses port 9000"
[ ! -f "$tmp/dry/instances/default/config.json" ] && pass "dry-run writes no config" || fail "dry-run writes no config"

docker_out="$(PAPERCLIP_HOME="$tmp/docker-dry" bash "$ROOT/scripts/personal/install.sh" --docker --dry-run)"
printf '%s\n' "$docker_out" | grep -q 'docker publish=127.0.0.1:9000' && pass "docker dry-run publishes localhost" || fail "docker dry-run publishes localhost"
printf '%s\n' "$docker_out" | grep -q 'memory cap=1g' && pass "docker dry-run caps memory at 1g" || fail "docker dry-run caps memory at 1g"

dispatch="$(PAPERCLIP_HOME="$tmp/dispatch" bash "$ROOT/scripts/install.sh" --personal --dry-run)"
printf '%s\n' "$dispatch" | grep -q 'mode=source' && pass "scripts/install.sh --personal dispatches" || fail "scripts/install.sh --personal dispatches"

help_out="$(bash "$ROOT/scripts/install.sh" --help)"
printf '%s\n' "$help_out" | grep -q 'paperclip.ing/install.sh' && pass "official installer help is unchanged" || fail "official installer help is unchanged"

mkdir -p "$tmp/switch/personal"
cat >"$tmp/switch/personal/state.env" <<EOF
PAPERCLIP_CHECKOUT='$tmp/checkout'
PAPERCLIP_HOME='$tmp/switch'
PAPERCLIP_PORT='9000'
PAPERCLIP_UPDATE_BRANCH='master'
PAPERCLIP_MODE='docker'
PAPERCLIP_NODE=''
PAPERCLIP_REPO_URL='https://example.invalid/paperclip.git'
EOF
if PAPERCLIP_HOME="$tmp/switch" bash "$ROOT/scripts/personal/install.sh" >"$tmp/switch.out" 2>"$tmp/switch.err"; then
  fail "mode switch is refused"
else
  pass "mode switch is refused"
fi
grep -q "Data was not modified" "$tmp/switch.err" && pass "mode switch keeps data" || fail "mode switch keeps data"
[ ! -f "$tmp/switch/instances/default/config.json" ] && pass "refused install wrote no config" || fail "refused install wrote no config"

if [ "$failures" -eq 0 ]; then
  printf 'personal setup tests passed\n'
else
  printf '%s personal setup tests failed\n' "$failures" >&2
  exit 1
fi
