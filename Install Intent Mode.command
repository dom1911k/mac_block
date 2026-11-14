#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  Install Intent Mode PERMANENTLY — double-click this file.
#
#  Unlike the test, this starts at every boot and doesn't switch itself off.
#  Only do this after testing. You can always remove it again:
#    • lock screen → "Emergency off…" (needs your admin password), or
#    • "Stop Intent Mode.command", or
#    • Terminal (in Claude mode):  sudo intentmode emergency-off
# ─────────────────────────────────────────────────────────────────────────────
cd "$(dirname "$0")" || exit 1
pause() { echo; read -r -p "Press Enter to close this window." _; }
clear
echo
echo "  Install Intent Mode (permanent)"
echo "  ───────────────────────────────"
echo
if [ -f "/Library/Application Support/IntentMode/test-mode.json" ]; then
  echo "  A test is running. Click \"Stop test now\" first (or wait until it ends), then run this again."
  pause; exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "  Run 'Try Intent Mode.command' once first (it installs Apple's developer tools)."
  pause; exit 1
fi
echo "  Building (a few minutes)…"
LOG="$HOME/Desktop/IntentMode-build-log.txt"
if ! bash scripts/build.sh "install" >"$LOG" 2>&1; then
  echo "  ❌ The build failed — nothing was installed. Send Claude IntentMode-build-log.txt from your Desktop."
  pause; exit 1
fi
rm -f "$LOG"
VER="$(tr -d ' \n' < VERSION)"
echo
echo "  macOS will ask for your Mac password. Nothing appears while you type — that's normal."
echo
sudo bash "build/IntentMode-$VER/install.sh"
pause
