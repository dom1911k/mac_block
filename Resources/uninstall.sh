#!/bin/bash
# Removes Intent Mode completely.
#
#   sudo "/Library/Application Support/IntentMode/uninstall.sh"
#
# Runs emergency-off first (firewall rules removed, DNS restored), then deletes all files.
BASE="/Library/Application Support/IntentMode"

if [ "$(id -u)" != 0 ]; then
  echo "Run with sudo:  sudo \"$0\""
  exit 1
fi

read -r -p "This removes Intent Mode completely. Type UNINSTALL to continue: " answer
[ "$answer" = "UNINSTALL" ] || { echo "Cancelled."; exit 1; }

# Copy the emergency script out first, since we delete its folder afterwards.
TMP="$(mktemp -d)"
if [ -f "$BASE/emergency-off.sh" ]; then
  cp "$BASE/emergency-off.sh" "$TMP/off.sh"
  bash "$TMP/off.sh"
  cat "$BASE/emergency-off.log" 2>/dev/null | tail -n 20
fi

rm -f /Library/LaunchDaemons/com.intentmode.daemon.plist /Library/LaunchAgents/com.intentmode.screen.plist
# Clear the "disabled" flags emergency-off left behind.
launchctl enable system/com.intentmode.daemon 2>/dev/null
UID_C="$(stat -f %u /dev/console)"
[ "$UID_C" != 0 ] && launchctl enable "gui/$UID_C/com.intentmode.screen" 2>/dev/null

if [ -L /usr/local/bin/intentmode ]; then rm -f /usr/local/bin/intentmode; fi
rm -f /var/run/intentmode.sock

read -r -p "Keep your config.json and logs (copied to /Users/Shared/IntentMode/backup)? [Y/n] " keep
if [ "$keep" != "n" ] && [ "$keep" != "N" ]; then
  mkdir -p /Users/Shared/IntentMode/backup
  cp "$BASE"/config.json "$BASE"/*.log "$BASE"/sessions.jsonl /Users/Shared/IntentMode/backup/ 2>/dev/null
  echo "Saved to /Users/Shared/IntentMode/backup"
fi
rm -rf "$BASE" "$TMP"

cat <<EOF

Intent Mode is uninstalled.
Still to do by hand (if you installed it): remove the "Intent Mode – Chrome policies" profile in
System Settings → General → Device Management.
EOF
