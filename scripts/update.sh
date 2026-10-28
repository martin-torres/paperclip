#!/usr/bin/env bash
# Manual update for this fork. See PERSONAL_SETUP.md.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/env bash "$script_dir/personal/update.sh" "$@"
