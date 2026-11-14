# Testing Intent Mode — the easy way

No virtual machine and almost no Terminal. The test runs on your normal Mac and **always switches itself off**:

- when the time you picked (10, 20 or 60 minutes) is up,
- when you restart your Mac,
- or when you click **Stop test now** on the yellow bar.

Terminal is never closed during a test, so you always have a way out.

## 1. Get the files (2 minutes)

1. Open <https://github.com/dom1911k/mac_block/tree/claude/new-session-e0vhgg> in your browser.
2. Click the green **Code** button → **Download ZIP**.
3. Double-click the ZIP in your Downloads folder to unpack it.

## 2. Start the test

1. Open the unpacked folder and double-click **Try Intent Mode.command**.
   - If macOS says it "cannot be opened" or "could not verify": open **System Settings → Privacy & Security**,
     scroll down and click **Open Anyway** next to "Try Intent Mode.command". Then double-click it again.
2. A Terminal window opens and walks you through it:
   - **Step 1, the first time only:** a window asks to install Apple's developer tools. Click **Install**, then
     **Agree**, and wait (5–15 min). The Terminal window continues by itself.
   - **Step 2:** building (3–6 minutes). You just wait.
   - **Step 3:** pick the length of the test and type your Mac password (nothing shows while you type).

If the build fails, nothing is installed and your Mac is unchanged. Send me the file
`IntentMode-build-log.txt` from your Desktop.

## 3. Things to try

Just play with it. Here are good things to check:

1. The screen says **What are you here for?** You can't switch apps (⌘-Tab) or open Force Quit (⌘⌥Esc).
2. Press ⌘Space and open Notes. It closes again within a second.
3. Pick **Journal**, try to start with a short intent (fewer than 8 words): it won't let you. Try pasting text:
   it won't let you either. Type a real sentence and start.
4. Chrome opens on your journal document. Sign in to Google if needed and type something.
5. In Chrome, open a new window (⌘N) and try `reddit.com`, `youtube.com` and `google.com`. None of them load.
6. The small timer window is in the top-right corner. Try **+10 min…**: it makes you wait 60 seconds, then asks
   for a reason.
7. Click **End session → End now**. Chrome closes and the lock screen comes back.
8. Start **Claude / vibe coding**: claude.ai and github.com work, youtube.com doesn't.
9. Try to open Safari at any time. It always closes.
10. Click **Stop test now**. Within a few seconds everything is back to normal and websites work again.

Also worth trying once: start a test and **restart the Mac** in the middle of it. After the restart Intent Mode is
gone and the internet works.

## 4. Tell me how it went

Send me what worked, what didn't, and anything that felt confusing. After every test the logs are saved in the
folder **/Users/Shared/IntentMode/last-logs**. In Finder press ⇧⌘G and paste that path, then send me
`daemon.log` from there.

## If something seems stuck

In this order:

1. Click **Stop test now** on the yellow bar.
2. Double-click **Stop Intent Mode.command** in the downloaded folder (Terminal stays usable during tests).
3. Restart the Mac: Apple menu → Restart, or hold the power button for 10 seconds, then press it again.
   A test install never survives a restart.
4. Or simply wait. The test ends on its own when its time is up.
