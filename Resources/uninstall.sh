#!/bin/bash
# Removes Intent Mode completely.
#
#   sudo "/Library/Application Support/IntentMode/uninstall.sh"          asks before removing
#   sudo "/Library/Application Support/IntentMode/uninstall.sh" --yes    no questions (used by test mode)
#
# Runs emergency-off first (firewall rules removed, DNS restored), then deletes all files.
# Logs are always copied to /Users/Shared/IntentMode/last-logs/ first, so problems can be looked at afterwards.
BASE="/Library/Application Support/IntentMode"
YES=""
DELAY=""
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;;
    --delay) DELAY=1 ;;
  esac
done

if [ "$(id -u)" != 0 ]; then
  echo "Run with sudo:  sudo \"$0\""
  exit 1
fi

if [ -z "$YES" ]; then
  read -r -p "This removes Intent Mode completely. Type UNINSTALL to continue: " answer
  [ "$answer" = "UNINSTALL" ] || { echo "Cancelled."; exit 1; }
fi

if [ -n "$DELAY" ]; then
  # Started by the daemon (from the intent screen): detach from it and let it send its reply first.
  exec >/dev/null 2>&1 < /dev/null
  sleep 2
fi

# Save logs before anything is deleted.
LOGS=/Users/Shared/IntentMode/last-logs
mkdir -p "$LOGS"
cp "$BASE"/*.log "$BASE"/sessions.jsonl "$BASE"/config.json "$LOGS"/ 2>/dev/null
CONSOLE_USER="$(stat -f %Su /dev/console)"
if [ "$CONSOLE_USER" != root ]; then
  cp "$(eval echo "~$CONSOLE_USER")/Library/Logs/IntentMode-screen.log" "$LOGS"/ 2>/dev/null
fi
chmod -R a+rX /Users/Shared/IntentMode 2>/dev/null

# Stop the backup timer of a test install.
if [ -f "$BASE/test-timer.pid" ]; then
  kill "$(cat "$BASE/test-timer.pid")" 2>/dev/null
fi

# Copy the emergency script out first, since we delete its folder afterwards.
TMP="$(mktemp -d)"
if [ -f "$BASE/emergency-off.sh" ]; then
  cp "$BASE/emergency-off.sh" "$TMP/off.sh"
  bash "$TMP/off.sh"
fi
cp "$BASE/emergency-off.log" "$LOGS"/ 2>/dev/null

rm -f /Library/LaunchDaemons/com.intentmode.daemon.plist /Library/LaunchAgents/com.intentmode.screen.plist
rm -f /Library/LaunchDaemons/com.intentmode.testcleanup.plist
rm -f /etc/sudoers.d/zz-intentmode-lockdown   # lock-down's sudo rule
# Clear the "disabled" flags emergency-off left behind, so a later install starts normally.
launchctl enable system/com.intentmode.daemon 2>/dev/null
UID_C="$(stat -f %u /dev/console)"
[ "$UID_C" != 0 ] && launchctl enable "gui/$UID_C/com.intentmode.screen" 2>/dev/null

if [ -L /usr/local/bin/intentmode ]; then rm -f /usr/local/bin/intentmode; fi
rm -f /var/run/intentmode.sock
rm -rf "$BASE" "$TMP"

cat <<EOF

Intent Mode is removed. Your logs are in $LOGS
If you installed the Chrome profile, remove "Intent Mode – Chrome policies" in
System Settings → General → Device Management.
EOF
