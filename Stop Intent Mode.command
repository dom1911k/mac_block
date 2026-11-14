#!/bin/bash
# Stop Intent Mode — double-click this file to turn Intent Mode off and remove it from this Mac.
BASE="/Library/Application Support/IntentMode"
clear
echo
echo "  Stop Intent Mode"
echo "  ────────────────"
if [ -f "$BASE/lockdown.json" ]; then
  echo "  Lock-down is on, so Intent Mode can't be removed from here."
  echo "  Use \"Turn off (one-time, 24 h)\" on the lock screen if it's still available."
elif [ ! -f "$BASE/uninstall.sh" ]; then
  echo "  Intent Mode isn't installed. Nothing to do."
  if [ -f /Library/LaunchDaemons/com.intentmode.testcleanup.plist ]; then
    sudo rm -f /Library/LaunchDaemons/com.intentmode.testcleanup.plist
  fi
else
  echo "  macOS will ask for your Mac password. Nothing appears while you type — that's normal."
  echo
  sudo bash "$BASE/uninstall.sh" --yes
fi
echo
read -r -p "  Press Enter to close this window." _
