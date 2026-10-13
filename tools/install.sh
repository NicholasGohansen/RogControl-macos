#!/bin/bash
# Installs rogd and rogctl (run from the repo after ./build.sh, with sudo).
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
# The kext's brightness-key device (Fn+F7/F8) is a keyboard to macOS; without a keyboard type
# for it (vendor 0x0B05, product 0) Keyboard Setup Assistant asks to identify it at every boot.
defaults write /Library/Preferences/com.apple.keyboardtype keyboardtype -dict-add "0-2821-0" -int 40
plist=/Library/LaunchDaemons/com.pengubow.rogd.plist
launchctl bootout system/com.pengubow.rogd 2>/dev/null || true
install -m 644 -o root -g wheel "$here/rogd/com.pengubow.rogd.plist" "$plist"
launchctl bootstrap system "$plist"
echo "rogd running; log: /Library/Logs/rogd.log"
