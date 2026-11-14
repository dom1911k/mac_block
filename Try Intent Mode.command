#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  Try Intent Mode — double-click this file.
#
#  It builds Intent Mode and starts a TEST that switches itself off:
#    • when the time you pick is up,
#    • when you restart your Mac,
#    • or when you click "Stop test now" on the yellow bar.
# ─────────────────────────────────────────────────────────────────────────────
cd "$(dirname "$0")" || exit 1

pause() { echo; read -r -p "Press Enter to close this window." _; }

clear
cat <<'TXT'

   ┌──────────────────────────────────────┐
   │        Try Intent Mode (test)        │
   └──────────────────────────────────────┘

TXT

if [ "$(uname -m)" != "arm64" ]; then
  echo "This needs a Mac with Apple Silicon (M1 or newer)."; pause; exit 1
fi
if [ -f "/Library/Application Support/IntentMode/config.json" ] && [ ! -f "/Library/Application Support/IntentMode/test-mode.json" ]; then
  echo "Intent Mode is already installed for real on this Mac, so a test can't be started."
  echo "Use 'Stop Intent Mode.command' first if you want to remove it."
  pause; exit 1
fi

# ── Step 1: Apple's developer tools ──────────────────────────────────────────
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Step 1 of 3 — Apple's free developer tools (one time only)"
  echo
  echo "  A window will pop up: click \"Install\", then \"Agree\"."
  echo "  It takes about 5–15 minutes. This window waits and continues by itself."
  echo
  xcode-select --install >/dev/null 2>&1
  printf "  Waiting"
  until xcrun --find swift >/dev/null 2>&1; do sleep 10; printf "."; done
  echo " done."
  echo
else
  echo "Step 1 of 3 — developer tools: already installed ✓"
  echo
fi

# Check that the tools actually work. A known problem: after a tools update, an old file is left
# behind ("redefinition of module 'SwiftBridging'") and every Swift program fails. A clean reinstall fixes it.
tools_work() {
  local d; d="$(mktemp -d)"
  printf 'import Foundation\nprint("ok")\n' > "$d/t.swift"
  xcrun swiftc -typecheck "$d/t.swift" >"$d/out.txt" 2>&1
  local r=$?
  cp "$d/out.txt" /tmp/intentmode-toolcheck.txt 2>/dev/null
  rm -rf "$d"
  return $r
}
if ! tools_work; then
  echo "  ⚠️  Apple's developer tools on this Mac are damaged (a leftover from an earlier update)."
  echo "     This is not caused by Intent Mode. The fix is a clean reinstall of the tools:"
  echo "     they are removed and downloaded again (5–15 minutes). Nothing else is touched."
  echo
  read -r -p "  Press Enter to reinstall them (or close this window to cancel). " _
  echo
  echo "  macOS will ask for your Mac password. Nothing appears while you type — that's normal."
  sudo rm -rf /Library/Developer/CommandLineTools
  sudo xcode-select --reset 2>/dev/null
  echo
  echo "  A window will pop up: click \"Install\", then \"Agree\". This window waits."
  xcode-select --install >/dev/null 2>&1
  printf "  Waiting"
  until xcrun --find swift >/dev/null 2>&1; do sleep 10; printf "."; done
  echo " done."
  if ! tools_work; then
    echo
    echo "  ❌ The tools still don't work. Please send Claude this text:"
    cat /tmp/intentmode-toolcheck.txt
    pause; exit 1
  fi
  echo "  Developer tools repaired ✓"
  echo
fi

# ── Step 2: build ────────────────────────────────────────────────────────────
echo "Step 2 of 3 — building Intent Mode (3–6 minutes the first time)…"
LOG="$HOME/Desktop/IntentMode-build-log.txt"
if ! bash scripts/build.sh "test build" >"$LOG" 2>&1; then
  echo
  echo "  ❌ The build failed. Nothing was installed — your Mac is unchanged."
  echo
  echo "  Please send Claude the file  IntentMode-build-log.txt  from your Desktop."
  open -R "$LOG" 2>/dev/null
  pause; exit 1
fi
rm -f "$LOG"
VER="$(tr -d ' \n' < VERSION)"
echo "  Built ✓"
echo

# ── Step 3: start the test ───────────────────────────────────────────────────
echo "Step 3 of 3 — how long should the test run?"
echo
echo "   1) 10 minutes"
echo "   2) 20 minutes   (recommended)"
echo "   3) 60 minutes"
echo
read -r -p "  Type 1, 2 or 3 and press Enter [2]: " choice
case "$choice" in
  1) MIN=10 ;;
  3) MIN=60 ;;
  *) MIN=20 ;;
esac

cat <<TXT

  What happens now:
   • Your screen is replaced by "What are you here for?".
   • Other apps are closed (save your work first!). Terminal stays open.
   • Internet only works for the mode you start.

  Ways out — all of them work, none needs the Terminal:
   • the yellow bar's  "Stop test now"  button,
   • wait $MIN minutes,
   • restart your Mac (Apple menu, or hold the power button).

TXT
read -r -p "  Save your work, then press Enter to start (or close this window to cancel). " _

echo
echo "  macOS will ask for your Mac password (the one you log in with)."
echo "  Nothing appears while you type — that's normal. Press Enter when done."
echo
if sudo bash "build/IntentMode-$VER/install.sh" --test "$MIN"; then
  echo "  You can close this window."
else
  echo
  echo "  ❌ Starting the test failed. Restart your Mac to be sure everything is off,"
  echo "     then send Claude a screenshot of this window."
  pause; exit 1
fi
