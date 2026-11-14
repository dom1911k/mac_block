#!/bin/bash
# First-time install of Intent Mode. Run from inside a built package:
#
#   sudo ./install.sh
#
# What it does:
#   - copies this build to /Library/Application Support/IntentMode/versions/<version>
#   - installs config.json (only if none exists), the emergency-off and uninstall scripts
#   - installs and starts the root LaunchDaemon (enforcement) and the LaunchAgent (intent screen)
# Undo: sudo intentmode emergency-off   (stops everything)   or   sudo "/Library/Application Support/IntentMode/uninstall.sh"
set -euo pipefail

PKG="$(cd "$(dirname "$0")" && pwd)"
BASE="/Library/Application Support/IntentMode"

if [ "$(id -u)" != 0 ]; then
  echo "Run with sudo:  sudo \"$0\""
  exit 1
fi
for f in VERSION bin/intentmoded bin/intentguard bin/intentmode IntentScreen.app/Contents/MacOS/IntentScreen \
         Resources/config.default.json Resources/update_pubkey.b64 manifest.json manifest.sig; do
  [ -e "$PKG/$f" ] || { echo "This doesn't look like a complete build: missing $f"; exit 1; }
done
VER="$(tr -d ' \n' < "$PKG/VERSION")"

if launchctl print system/com.intentmode.daemon >/dev/null 2>&1; then
  echo "Intent Mode is already installed and running."
  echo "To install a new build use:  intentmode update propose \"$PKG\""
  echo "To reinstall from scratch:   sudo \"$BASE/uninstall.sh\"  then run this again."
  exit 1
fi

cat <<EOF

  Intent Mode $VER — first install
  ─────────────────────────────────
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
chown -R root:wheel "$BASE"
chmod 755 "$BASE"

echo "==> Checking the installed config"
"$BASE/current/bin/intentmoded" --self-test --config "$BASE/config.json"

mkdir -p /usr/local/bin
ln -sf "$BASE/current/bin/intentmode" /usr/local/bin/intentmode

echo "==> Installing launchd jobs"
install -m 644 -o root -g wheel "$PKG/Resources/launchd/com.intentmode.daemon.plist" /Library/LaunchDaemons/com.intentmode.daemon.plist
install -m 644 -o root -g wheel "$PKG/Resources/launchd/com.intentmode.screen.plist" /Library/LaunchAgents/com.intentmode.screen.plist

# Chrome policy profile for you to install by double-click (needs admin approval in System Settings).
mkdir -p /Users/Shared/IntentMode
cp "$PKG/Resources/chrome/IntentMode-Chrome.mobileconfig" /Users/Shared/IntentMode/
chmod 644 /Users/Shared/IntentMode/IntentMode-Chrome.mobileconfig

launchctl enable system/com.intentmode.daemon
launchctl bootstrap system /Library/LaunchDaemons/com.intentmode.daemon.plist
CONSOLE_UID="$(stat -f %u /dev/console)"
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
