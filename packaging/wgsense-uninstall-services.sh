#!/bin/zsh
set -euo pipefail

uid="${SUDO_UID:-$(id -u)}"

launchctl bootout system /Library/LaunchDaemons/com.wgsense.daemon.plist 2>/dev/null || true
launchctl bootout "gui/$uid" "/Users/${SUDO_USER:-$USER}/Library/LaunchAgents/com.wgsense.receive-mover.plist" 2>/dev/null || true
launchctl bootout "gui/$uid" "/Users/${SUDO_USER:-$USER}/Library/LaunchAgents/com.wgsense.passive.plist" 2>/dev/null || true

pkill -f '/usr/local/libexec/wgsense-daemon' 2>/dev/null || true

rm -f /Library/LaunchDaemons/com.wgsense.daemon.plist
rm -f "/Users/${SUDO_USER:-$USER}/Library/LaunchAgents/com.wgsense.receive-mover.plist"
rm -f "/Users/${SUDO_USER:-$USER}/Library/LaunchAgents/com.wgsense.passive.plist"
rm -f /usr/local/libexec/wgsense-daemon
rm -f /usr/local/libexec/wgsense-receive-mover

echo "WgSense services removed. User profiles and transfer data were kept."
