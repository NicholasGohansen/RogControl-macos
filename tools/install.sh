#!/bin/bash
# Installs rogd, rogctl and the menu bar app (run from the repo after ./build.sh, with sudo).
#   sudo tools/install.sh [config.json]
# The kext itself is loaded by OpenCore (EFI/OC/Kexts/RogControl.kext + config.plist entry).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
build="$here/build/Release"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
install -d /usr/local/bin "/Library/Application Support/RogControl"
install -m 755 "$build/rogd" "$build/rogctl" /usr/local/bin/
if [ $# -ge 1 ]; then
	install -m 644 "$1" "/Library/Application Support/RogControl/config.json"
	echo "installed config from $1"
fi
plist=/Library/LaunchDaemons/com.pengubow.rogd.plist
launchctl bootout system/com.pengubow.rogd 2>/dev/null || true
install -m 644 -o root -g wheel "$here/rogd/com.pengubow.rogd.plist" "$plist"
launchctl bootstrap system "$plist"
echo "rogd running; log: /Library/Logs/rogd.log"

# Menu bar app, started at login (for every user; the panel's controls need an administrator)
if [ -d "$build/RogControl.app" ]; then
	ditto "$build/RogControl.app" /Applications/RogControl.app
	agent=/Library/LaunchAgents/com.pengubow.RogControl.plist
	install -m 644 -o root -g wheel "$here/menubar/com.pengubow.RogControl.plist" "$agent"
	user="$(stat -f %Su /dev/console)"
	if [ "$user" != root ]; then
		uid="$(id -u "$user")"
		launchctl bootout "gui/$uid/com.pengubow.RogControl" 2>/dev/null || true
		# bootstrap fails while the old instance is still being unloaded
		for _ in 1 2 3 4 5 6 7 8 9 10; do
			launchctl print "gui/$uid/com.pengubow.RogControl" >/dev/null 2>&1 || break
			sleep 0.5
		done
		pkill -u "$uid" -x RogControl 2>/dev/null || true  # a copy opened by hand
		sleep 0.5
		launchctl bootstrap "gui/$uid" "$agent"
		echo "menu bar app running for $user"
	fi
fi
