#!/bin/bash
# Intent Mode — EMERGENCY OFF (dev builds / Phases 1–3).
#
#   sudo intentmode emergency-off           remove all enforcement, stays off across reboots
#   sudo intentmode emergency-off --undo    turn enforcement back on
#
# Off means: daemon and intent screen stopped and disabled, pf anchor removed, DNS restored.
# Works even when the daemon is broken: it only uses launchctl, pfctl and networksetup.

BASE="/Library/Application Support/IntentMode"
ANCHOR="com.apple/000.intentmode"
DAEMON=com.intentmode.daemon
AGENT=com.intentmode.screen

if [ "$(id -u)" != 0 ]; then
  echo "Run with sudo:  sudo intentmode emergency-off"
  exit 1
fi

console_uid() { stat -f %u /dev/console; }

if [ "${1:-}" = "--undo" ]; then
  echo "Turning Intent Mode back on…"
  launchctl enable "system/$DAEMON"
  launchctl bootstrap system "/Library/LaunchDaemons/$DAEMON.plist" 2>/dev/null || launchctl kickstart "system/$DAEMON"
  UID_C="$(console_uid)"
  if [ "$UID_C" != 0 ]; then
    launchctl enable "gui/$UID_C/$AGENT"
    launchctl bootstrap "gui/$UID_C" "/Library/LaunchAgents/$AGENT.plist" 2>/dev/null || launchctl kickstart "gui/$UID_C/$AGENT"
  fi
  echo "Done. Enforcement is active again."
  exit 0
fi

if [ "${1:-}" = "--delay" ]; then
  # Started by the daemon (intent screen button): no terminal, so log to a file only,
  # and give the daemon a moment to send its reply first.
  exec >>"$BASE/emergency-off.log" 2>&1 < /dev/null
  sleep 2
else
  # Started from a Terminal: show output and also keep a log.
  exec > >(tee -a "$BASE/emergency-off.log") 2>&1
fi
echo "=== emergency off: $(date) ==="

echo "Stopping the daemon and intent screen (and keeping them off across reboots)…"
launchctl disable "system/$DAEMON"
launchctl bootout "system/$DAEMON" 2>/dev/null
for uid in $(console_uid) $(ps -axo uid=,command= | awk '/IntentScreen.app/ && !/awk/ {print $1}' | sort -u); do
  [ "$uid" = 0 ] && continue
  launchctl disable "gui/$uid/$AGENT"
  launchctl bootout "gui/$uid/$AGENT" 2>/dev/null
done
pkill -f "IntentScreen.app/Contents/MacOS/IntentScreen" 2>/dev/null
pkill -x intentguard 2>/dev/null
pkill -x intentmoded 2>/dev/null

echo "Removing firewall rules…"
/sbin/pfctl -a "$ANCHOR" -F all 2>/dev/null
if [ -f "$BASE/pf-token.txt" ]; then
  /sbin/pfctl -X "$(cat "$BASE/pf-token.txt")" 2>/dev/null
  rm -f "$BASE/pf-token.txt"
fi

echo "Restoring DNS…"
restored=""
if [ -f "$BASE/dns-backup.txt" ]; then
  while IFS=$'\t' read -r svc servers; do
    [ -z "$svc" ] && continue
    # shellcheck disable=SC2086
    networksetup -setdnsservers "$svc" $servers && restored="$restored|$svc|"
    echo "  $svc → $servers"
  done < "$BASE/dns-backup.txt"
  rm -f "$BASE/dns-backup.txt"
fi
# Any service still pointing at our resolver goes back to automatic (DHCP).
networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//' | while read -r svc; do
  [ -z "$svc" ] && continue
  if networksetup -getdnsservers "$svc" 2>/dev/null | grep -q '^127\.0\.0\.1$'; then
    networksetup -setdnsservers "$svc" Empty
    echo "  $svc → automatic"
  fi
done
dscacheutil -flushcache
killall -HUP mDNSResponder 2>/dev/null

echo "Done. Intent Mode is OFF (also after a reboot)."
echo "Turn it back on with:  sudo intentmode emergency-off --undo"
