#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  Update Intent Mode — double-click this file.
#
#  Downloads the newest version from GitHub, builds it, and installs it as an update.
#  Works while Intent Mode is running (e.g. during a Claude session, which allows Terminal),
#  no admin password needed. Your settings, usage and logs are kept.
# ─────────────────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/dom1911k/mac_block.git"
BRANCH="claude/new-session-e0vhgg"
HOME_COPY="$HOME/IntentMode"
BASE="/Library/Application Support/IntentMode"

pause() { echo; read -r -p "Press Enter to close this window." _; }
cd "$(dirname "$0")" || exit 1
clear
echo
echo "  Update Intent Mode"
echo "  ──────────────────"
echo

# A ZIP download has no update connection; set up a permanent copy in ~/IntentMode once.
if [ ! -d .git ]; then
  if [ -d "$HOME_COPY/.git" ]; then
    cd "$HOME_COPY" || exit 1
  else
    cat <<TXT
  One-time setup: this copy was downloaded as a ZIP, so it can't update itself.
  I'll make a copy in your home folder (~/IntentMode) that can.

  GitHub will ask you to log in once (your Mac remembers it afterwards):
    • Username: your GitHub username
    • Password: a GitHub "personal access token" — NOT your GitHub password.
      Make one at github.com → your picture → Settings → Developer settings →
      Personal access tokens → Fine-grained tokens → Generate new token.
      Repository access: only "mac_block"; Permissions → Contents: Read-only.
      Copy the token and paste it when asked (nothing shows while pasting — that's normal).

TXT
    read -r -p "  Press Enter to continue (or close this window to cancel). " _
    git clone -b "$BRANCH" "$REPO_URL" "$HOME_COPY" || { echo; echo "  ❌ Download failed (wrong login?). Try again."; pause; exit 1; }
    cd "$HOME_COPY" || exit 1
    echo
    echo "  ✅ Set up. From now on, use 'Update Intent Mode.command' inside the IntentMode folder"
    echo "     in your home folder (Finder → Go → Home → IntentMode)."
    open "$HOME_COPY" 2>/dev/null
    echo
  fi
fi

echo "  Getting the newest version…"
git checkout -- Sources/IntentCore/BuildInfo.swift 2>/dev/null   # the build stamps the version here
if ! git pull --ff-only; then
  echo
  echo "  ❌ Couldn't get the newest version. Is the internet reachable?"
  echo "     (During a session, use Claude mode — it allows GitHub.)"
  pause; exit 1
fi
NEW="$(tr -d ' \n' < VERSION)"
CUR="$(intentmode version 2>/dev/null | awk '{print $1}')"
echo "  Installed: ${CUR:-not installed}    Newest: $NEW"
echo

if [ ! -f "$BASE/config.json" ]; then
  echo "  Intent Mode isn't installed right now. Use 'Try Intent Mode.command' (test)"
  echo "  or 'Install Intent Mode.command' (permanent) in this folder: $(pwd)"
  open "$(pwd)" 2>/dev/null
  pause; exit 0
fi
if [ "$CUR" = "$NEW" ]; then
  echo "  ✅ Already up to date."
  pause; exit 0
fi

echo "  Building $NEW (a few minutes)…"
LOG="$HOME/Desktop/IntentMode-build-log.txt"
if ! bash scripts/build.sh "update to $NEW" >"$LOG" 2>&1; then
  echo "  ❌ The build failed — nothing was changed. Send Claude the file IntentMode-build-log.txt from your Desktop."
  pause; exit 1
fi
rm -f "$LOG"

echo "  Installing the update…"
if intentmode update propose "build/IntentMode-$NEW.tar.gz"; then
  echo
  echo "  ✅ Updated to $NEW. The intent screen restarts by itself in a few seconds."
  echo "     If the new version has a problem, it switches back to $CUR automatically,"
  echo "     or run:  intentmode update rollback"
else
  echo
  echo "  ❌ The update was refused (see the message above). Nothing was changed."
fi
pause
