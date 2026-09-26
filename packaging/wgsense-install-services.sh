#!/bin/zsh
set -euo pipefail

if [[ "$(/usr/bin/id -u)" != "0" ]]; then
  echo "Run with administrator privileges to install the persistent WgSense service." >&2
  exit 1
fi
daemon_src="${1:?Missing bundled daemon}"
mover_src="${2:?Missing receive mover}"
target_user="${3:-${SUDO_USER:-}}"
if [[ -z "$target_user" || "$target_user" == "root" ]]; then
  echo "Pass the non-root login user explicitly." >&2
  exit 1
fi

# Stage before handing off to a separate launchd installer. stdout is operation JSON.
exec "$daemon_src" --install-service --source-daemon "$daemon_src" \
  --source-mover "$mover_src" --target-user "$target_user"
