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
