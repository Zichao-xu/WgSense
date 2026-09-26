#!/bin/zsh
set -euo pipefail
if [[ "$(/usr/bin/id -u)" != "0" ]]; then
  echo "Administrator privileges are required." >&2
  exit 1
fi
target_user="${1:-${SUDO_USER:-}}"
if [[ -z "$target_user" || "$target_user" == "root" ]]; then
  echo "Pass the non-root login user explicitly." >&2
  exit 1
fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
daemon="$script_dir/../libexec/wgsense-daemon"
if [[ ! -x "$daemon" ]]; then
  daemon="/usr/local/libexec/wgsense-daemon"
fi
exec "$daemon" --uninstall-service --target-user "$target_user"
