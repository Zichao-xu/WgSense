#!/bin/zsh
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ "$(id -u)" != "0" ]]; then
  echo "Run with sudo so WgSense can install its privileged service." >&2
  exit 1
fi

target_user="${SUDO_USER:-$USER}"
target_home="$(dscl . -read "/Users/$target_user" NFSHomeDirectory | awk '{print $2}')"
if [[ -z "$target_home" || ! -d "$target_home" ]]; then
  echo "Cannot resolve home directory for $target_user" >&2
  exit 1
fi

daemon_src="${1:-/usr/local/libexec/wgsense-daemon}"
mover_src="${2:-$script_dir/wgsense-receive-mover.sh}"
daemon_dst="/usr/local/libexec/wgsense-daemon"
mover_dst="/usr/local/libexec/wgsense-receive-mover"
runtime_dir="$target_home/.local/share/wgsense"
incoming_dir="$runtime_dir/incoming"
download_dir="$target_home/Downloads/WgSense"
agent_dir="$target_home/Library/LaunchAgents"

if [[ ! -x "$daemon_src" ]]; then
  echo "Daemon binary is missing or not executable: $daemon_src" >&2
  exit 1
fi
if [[ ! -f "$mover_src" ]]; then
  echo "Receive mover script is missing: $mover_src" >&2
  exit 1
fi

install -d -m 0755 /usr/local/libexec
if [[ "$(realpath "$daemon_src")" != "$(realpath "$daemon_dst" 2>/dev/null || true)" ]]; then
  install -m 0755 "$daemon_src" "$daemon_dst"
fi
if [[ "$(realpath "$mover_src")" != "$(realpath "$mover_dst" 2>/dev/null || true)" ]]; then
  install -m 0755 "$mover_src" "$mover_dst"
fi

install -d -m 0755 "$runtime_dir" "$incoming_dir" "$download_dir" "$agent_dir"
chown -R "$target_user":staff "$runtime_dir" "$download_dir"

tmp_daemon="$(mktemp /tmp/com.wgsense.daemon.XXXXXX.plist)"
tmp_mover="$(mktemp /tmp/com.wgsense.receive-mover.XXXXXX.plist)"

sed \
  -e "s#__WGSENSE_DAEMON__#$daemon_dst#g" \
  -e "s#__WGSENSE_RUNTIME_DIR__#$runtime_dir#g" \
  -e "s#__WGSENSE_INCOMING_DIR__#$incoming_dir#g" \
  "$script_dir/com.wgsense.daemon.plist.template" > "$tmp_daemon"

sed \
  -e "s#__WGSENSE_RECEIVE_MOVER__#$mover_dst#g" \
  -e "s#__WGSENSE_INCOMING_DIR__#$incoming_dir#g" \
  -e "s#__WGSENSE_DOWNLOAD_DIR__#$download_dir#g" \
  "$script_dir/com.wgsense.receive-mover.plist.template" > "$tmp_mover"

plutil -lint "$tmp_daemon" "$tmp_mover" >/dev/null

install -m 0644 "$tmp_daemon" /Library/LaunchDaemons/com.wgsense.daemon.plist
install -m 0644 "$tmp_mover" "$agent_dir/com.wgsense.receive-mover.plist"
chown root:wheel /Library/LaunchDaemons/com.wgsense.daemon.plist
chown "$target_user":staff "$agent_dir/com.wgsense.receive-mover.plist"

launchctl bootstrap system /Library/LaunchDaemons/com.wgsense.daemon.plist 2>/dev/null || \
  launchctl kickstart -k system/com.wgsense.daemon

uid="$(id -u "$target_user")"
launchctl bootout "gui/$uid" "$agent_dir/com.wgsense.receive-mover.plist" 2>/dev/null || true
launchctl bootstrap "gui/$uid" "$agent_dir/com.wgsense.receive-mover.plist"

rm -f "$tmp_daemon" "$tmp_mover"
echo "WgSense services installed for $target_user."
