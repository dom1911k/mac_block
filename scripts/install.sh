#!/bin/bash
# Installs Intent Mode. Run from inside a built package:
#
#   sudo ./install.sh                 real install (starts at every boot)
#   sudo ./install.sh --test 20       TEST install for 20 minutes (what "Try Intent Mode.command" uses)
#
# Test install = same enforcement, but it can't stick:
#   - it uninstalls itself when the time is up (two independent timers),
#   - a restart always removes it (nothing is registered to start at boot; a one-shot cleanup runs instead),
#   - the lock screen has a "Stop test now" button (no password),
#   - Terminal is never quit.
#
# Undo a real install: sudo intentmode emergency-off   or   sudo "/Library/Application Support/IntentMode/uninstall.sh"
set -euo pipefail

PKG="$(cd "$(dirname "$0")" && pwd)"
BASE="/Library/Application Support/IntentMode"

TEST_MINUTES=""
if [ "${1:-}" = "--test" ]; then
  TEST_MINUTES="${2:-20}"
  case "$TEST_MINUTES" in ''|*[!0-9]*) echo "--test needs a number of minutes"; exit 1;; esac
  if [ "$TEST_MINUTES" -lt 1 ] || [ "$TEST_MINUTES" -gt 240 ]; then echo "Test length must be 1–240 minutes"; exit 1; fi
fi

if [ "$(id -u)" != 0 ]; then
  echo "Run with sudo:  sudo \"$0\" $*"
  exit 1
fi
for f in VERSION bin/intentmoded bin/intentguard bin/intentmode IntentScreen.app/Contents/MacOS/IntentScreen \
         Resources/config.default.json Resources/update_pubkey.b64 manifest.json manifest.sig; do
  [ -e "$PKG/$f" ] || { echo "This doesn't look like a complete build: missing $f"; exit 1; }
done
VER="$(tr -d ' \n' < "$PKG/VERSION")"

if launchctl print system/com.intentmode.daemon >/dev/null 2>&1; then
  if [ -n "$TEST_MINUTES" ] && [ -f "$BASE/test-mode.json" ]; then
    echo "==> Removing the previous test install first"
    bash "$BASE/uninstall.sh" --yes
  else
    echo "Intent Mode is already installed and running."
    echo "To install a new build use:  intentmode update propose \"$PKG\""
    echo "To reinstall from scratch:   sudo \"$BASE/uninstall.sh\"  then run this again."
    exit 1
  fi
fi

if [ -z "$TEST_MINUTES" ]; then
  cat <<EOF

  Intent Mode $VER — REAL install (starts at every boot)
  ──────────────────────────────────────────────────────
  After this, the Mac is LOCKED by default:
    • only the intent screen is shown; other apps are quit
    • network access only for the domains of the session you start
    • Safari, other browsers and VPN apps are always quit

  If anything goes wrong, from a Terminal (Claude mode allows Terminal) or via SSH:
      sudo intentmode emergency-off
  or on the intent screen: "Emergency off…" (dev builds) with your admin password.

EOF
  read -r -p "Type INSTALL to continue: " answer
  [ "$answer" = "INSTALL" ] || { echo "Cancelled."; exit 1; }
fi

echo "==> Self-test"
"$PKG/bin/intentmoded" --self-test --config "$PKG/Resources/config.default.json"

echo "==> Copying files to $BASE"
mkdir -p "$BASE/versions" "$BASE/blocklists"
rm -rf "$BASE/versions/$VER"
ditto "$PKG" "$BASE/versions/$VER"
ln -sfn "versions/$VER" "$BASE/current"
install -m 755 "$PKG/bin/intentguard" "$BASE/intentguard"
install -m 755 "$PKG/Resources/emergency-off.sh" "$BASE/emergency-off.sh"
install -m 755 "$PKG/Resources/uninstall.sh" "$BASE/uninstall.sh"
install -m 644 "$PKG/Resources/update_pubkey.b64" "$BASE/update_pubkey.b64"
if [ -f "$BASE/config.json" ]; then
  echo "    keeping existing config.json"
else
  install -m 644 "$PKG/Resources/config.default.json" "$BASE/config.json"
fi
cat > "$BASE/update-state.json" <<EOF
{ "current": "$VER", "knownGood": ["$VER"] }
EOF

if [ -n "$TEST_MINUTES" ]; then
  ENDS=$(( $(date +%s) + TEST_MINUTES * 60 ))
  echo "{ \"endsAt\": $ENDS }" > "$BASE/test-mode.json"
fi
chown -R root:wheel "$BASE"
chmod 755 "$BASE"

echo "==> Checking the installed config"
"$BASE/current/bin/intentmoded" --self-test --config "$BASE/config.json"

mkdir -p /usr/local/bin
ln -sf "$BASE/current/bin/intentmode" /usr/local/bin/intentmode

# Chrome policy profile for you to install by double-click (optional; needs admin approval in System Settings).
mkdir -p /Users/Shared/IntentMode
cp "$PKG/Resources/chrome/IntentMode-Chrome.mobileconfig" /Users/Shared/IntentMode/
chmod 644 /Users/Shared/IntentMode/IntentMode-Chrome.mobileconfig

CONSOLE_UID="$(stat -f %u /dev/console)"

if [ -n "$TEST_MINUTES" ]; then
  echo "==> Starting TEST mode for $TEST_MINUTES minutes"
  # launchd jobs are loaded from inside our folder, so nothing is registered to start at boot.
  mkdir -p "$BASE/launchd"
  install -m 644 -o root -g wheel "$PKG/Resources/launchd/com.intentmode.daemon.plist" "$BASE/launchd/com.intentmode.daemon.plist"
  install -m 644 -o root -g wheel "$PKG/Resources/launchd/com.intentmode.screen.plist" "$BASE/launchd/com.intentmode.screen.plist"
  # One-shot cleanup at the next boot: if the Mac restarts during the test, everything is removed.
  cat > /Library/LaunchDaemons/com.intentmode.testcleanup.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>com.intentmode.testcleanup</string>
	<key>ProgramArguments</key>
	<array><string>/bin/bash</string><string>$BASE/uninstall.sh</string><string>--yes</string></array>
	<key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
  chown root:wheel /Library/LaunchDaemons/com.intentmode.testcleanup.plist
  chmod 644 /Library/LaunchDaemons/com.intentmode.testcleanup.plist
  # Independent backup timer (works even if the daemon is broken).
  nohup /bin/bash -c "sleep $(( TEST_MINUTES * 60 + 30 )); [ -f '$BASE/test-mode.json' ] && /bin/bash '$BASE/uninstall.sh' --yes" \
    >/dev/null 2>&1 < /dev/null &
  echo $! > "$BASE/test-timer.pid"

  launchctl bootstrap system "$BASE/launchd/com.intentmode.daemon.plist"
  if [ "$CONSOLE_UID" != 0 ]; then
    launchctl bootstrap "gui/$CONSOLE_UID" "$BASE/launchd/com.intentmode.screen.plist" || true
  fi
  cat <<EOF

  ✅ Intent Mode TEST is running for $TEST_MINUTES minutes.

  It switches itself off when the time is up, when you restart the Mac,
  or when you click "Stop test now" on the yellow bar.

EOF
  exit 0
fi

echo "==> Installing launchd jobs"
install -m 644 -o root -g wheel "$PKG/Resources/launchd/com.intentmode.daemon.plist" /Library/LaunchDaemons/com.intentmode.daemon.plist
install -m 644 -o root -g wheel "$PKG/Resources/launchd/com.intentmode.screen.plist" /Library/LaunchAgents/com.intentmode.screen.plist
launchctl enable system/com.intentmode.daemon
launchctl bootstrap system /Library/LaunchDaemons/com.intentmode.daemon.plist
if [ "$CONSOLE_UID" != 0 ]; then
  launchctl enable "gui/$CONSOLE_UID/com.intentmode.screen"
  launchctl bootstrap "gui/$CONSOLE_UID" /Library/LaunchAgents/com.intentmode.screen.plist || true
fi

cat <<EOF

  Installed Intent Mode $VER.

  Next steps:
   1. Install the Chrome policies: double-click /Users/Shared/IntentMode/IntentMode-Chrome.mobileconfig,
      then System Settings → General → Device Management (or Privacy & Security → Profiles) → Install.
      Check it worked at chrome://policy in a session.
   2. Logs:   $BASE/daemon.log
   3. Config: sudo nano "$BASE/config.json"   (reloads automatically)

EOF
