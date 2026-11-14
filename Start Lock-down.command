#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  Start Lock-down (Phase 4) — double-click this file.
#
#  • sudo stops working for your account, Emergency off and learn are disabled
#  • loosening settings changes and updates wait 24 hours (tightening applies at once)
#  • ONE-TIME escape: "Turn off" on the lock screen takes effect after 24 hours.
#    It disappears for good once used, or once you click "Keep lock-down" and confirm.
# ─────────────────────────────────────────────────────────────────────────────
pause() { echo; read -r -p "Press Enter to close this window." _; }
clear
if [ ! -f "/Library/Application Support/IntentMode/config.json" ] || [ -f "/Library/Application Support/IntentMode/test-mode.json" ]; then
  echo
  echo "  Lock-down needs the permanent install. Run 'Install Intent Mode.command' first."
  pause; exit 1
fi
echo
echo "  macOS will ask for your Mac password one last time (nothing appears while you type)."
sudo /usr/local/bin/intentmode lockdown enable
pause
