# Using Intent Mode for real, and updating it

## Test vs. permanent

| | **Try Intent Mode.command** (test) | **Install Intent Mode.command** (permanent) |
|---|---|---|
| Starts at boot | No: a restart removes it | **Yes**: runs all the time, from login on |
| Switches itself off | After 10/20/60 min | Never |
| Way out | "Stop test now" button, no password | "Emergency off…" on the lock screen **with your admin password**, or `Stop Intent Mode.command` |
| Terminal | Never closed | Only allowed in Claude mode |

Recommended order: test a few times, then install permanently and use it daily. The plan's Phase 4 (after 7+ days
without problems) makes it hard to switch off in a weak moment: your account becomes a standard user, the admin
password goes behind a 72-hour delay, and loosening changes wait 24 hours.

## Updating: one double-click

**Once:** double-click **Update Intent Mode.command** in the downloaded folder. It makes a permanent copy in your
home folder (`~/IntentMode`) that can update itself. GitHub asks you to log in once; the window explains how to get
the access token. Your Mac remembers it.

**From then on:** whenever I tell you there's a new version, double-click
**Update Intent Mode.command** in the `IntentMode` folder in your home folder (Finder → Go → Home). It:

1. downloads the newest code from GitHub,
2. builds it,
3. installs it as an update. No password needed, and settings, usage, notes and logs are kept.

When Intent Mode is locked, start a **Claude** session first: it allows Terminal and GitHub, which the update needs.

If an update ever misbehaves, it switches back to the previous version by itself within 2 minutes. You can also
switch back at any time from Terminal:

```bash
intentmode update rollback
```

## Lock-down (Phase 4)

Start it with **Start Lock-down.command**. It asks for your Mac password one last time; type `LOCK DOWN` to
confirm. From then on:

- **`sudo` doesn't work** for your account. Emergency off, Stop Intent Mode and `learn` are disabled.
- **Settings:** use **Edit Settings.command**, during a Claude session, since it needs Terminal. It opens the settings in the nano editor: arrow keys to move, Control-O then Return to save, Control-X to quit. Tightening (shorter, fewer sites, lower limits) applies at once.
  Anything that loosens waits **24 hours** and shows as ⏳ pending on the lock screen, where you can cancel it.
  Editing `config.json` directly doesn't work: a loosening edit is undone within seconds.
- **Updates** (Update Intent Mode.command) are checked right away but install **24 hours** later.
  Rolling back to the previous version stays instant.
- **The delays can be raised, never lowered.**

### The one-time escape

The lock screen shows **Turn off (one-time, 24 h)…**. Request it, and lock-down switches off 24 hours later. You can
cancel in between without using it up. It works **once**.

When you're sure, click **Keep lock-down…** and type *I will keep using Intent Mode as intended*. The escape is then
gone for good.

### Limits (no separate admin account)

Your login password is still the admin password. System Settings (in Maintenance or the Open session) accepts it
for system changes, so a determined route remains. Lock-down makes every quick route slow, but it isn't a wall.

### Last resort: Recovery Mode

If Intent Mode is broken and the escape is gone:

1. Shut down. Hold the power button until "Loading startup options" appears, then choose **Options**.
2. Unlock the disk with your password if asked. Then open **Utilities → Terminal**.
3. Run:

   ```bash
   rm "/Volumes/Macintosh HD - Data/Library/LaunchDaemons/com.intentmode.daemon.plist"
   ```

   ```bash
   rm "/Volumes/Macintosh HD - Data/private/etc/sudoers.d/zz-intentmode-lockdown"
   ```

4. Restart normally, then remove the rest:

   ```bash
   sudo "/Library/Application Support/IntentMode/uninstall.sh"
   ```

Keep your FileVault recovery key somewhere safe, in case the password ever fails.
