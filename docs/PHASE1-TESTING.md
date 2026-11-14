# Phase 1: testing in a macOS VM, then the checklist

A virtual Mac lets you test everything (firewall, DNS, kiosk) without touching your real system. If something
locks up, you delete the VM.

## 1. Set up the VM (about 45 minutes, mostly downloading)

1. Download **UTM** from <https://mac.getutm.app> (free; the App Store version is the same app, paid).
2. In UTM, click **+ → Virtualize → macOS 12+**. UTM offers to download the latest macOS restore image (IPSW).
   Accept that, or pick a Tahoe 26 IPSW you downloaded from Apple.
3. Give it **8 GB memory, 4 CPU cores and a 64 GB disk**. Under **Shared Directory**, pick a folder on your Mac,
   for example `~/VMShare`.
4. Start the VM and go through macOS setup. Create an **admin** user and skip the Apple ID.
5. Inside the VM, open Terminal:
   ```bash
   xcode-select --install
   ```
6. Inside the VM, install **Google Chrome** and the **Claude desktop app** (from their websites).
7. Inside the VM, turn on **System Settings → General → Sharing → Remote Login**. That way you can always get in
   from your Mac's Terminal with `ssh <user>@<vm-ip>`, even if the screen is stuck. `ifconfig en0` inside the VM
   shows its IP.
8. **Make a backup copy of the VM now:** shut it down, then in UTM right-click it → **Clone**. If anything goes
   badly wrong, delete the broken VM and clone the backup again.

## 2. Build and install inside the VM

Inside the VM's Terminal:

```bash
git clone https://github.com/dom1911k/mac_block.git
```

The repository is private, so git asks for a login. Use your GitHub username and a personal access token as the
password. Alternatively, clone it on your real Mac into `~/VMShare` and use it from the shared folder at
`/Volumes/My Shared Files` in the VM.

```bash
cd mac_block
```

```bash
scripts/build.sh "phase 1 test"
```

```bash
sudo build/IntentMode-0.1.0/install.sh
```

Type `INSTALL`. The screen locks within a few seconds. Install the Chrome profile when you get the chance (see
the README).

**If anything looks wrong:** use **Emergency off…** on the lock screen, or from your Mac:

```bash
ssh <user>@<vm-ip> sudo intentmode emergency-off
```

Logs are in `/Library/Application Support/IntentMode/daemon.log` and `guard.log`. Paste anything odd back to me.

## 3. Checklist

Tick these off in the VM. Where it says "Terminal", use Claude mode (it allows Terminal), or SSH from your Mac.

### Lock screen and kiosk
- [ ] After install and after every login, only the intent screen is visible: no Dock, no menu bar.
- [ ] ⌘-Tab does nothing. ⌘⌥Esc (Force Quit) does nothing. ⌘Q does nothing.
- [ ] Open an app with Spotlight (⌘Space, e.g. "Notes"). It gets quit within a second.
- [ ] From Terminal (SSH), `killall IntentScreen`. It comes back within a few seconds.
- [ ] `launchctl bootout gui/$(id -u)/com.intentmode.screen` (SSH, as your user). It comes back within about 15 s.
- [ ] Sleep and wake the VM. The intent screen is still there.
- [ ] **Join Wi-Fi…** shows the menu bar for 2 minutes. **Done** hides it again.

### Starting a session
- [ ] A mode with a 7-word intent can't start. With 8 words it can.
- [ ] Pasting into the intent box doesn't work (⌘V, right-click → Paste, drag and drop).
- [ ] Journal opens Chrome as an app window on your journal doc. You can sign in to Google and type.
- [ ] The timer panel sits top-right and counts down.
- [ ] After the daily limit (e.g. Journal 2×), the mode is greyed out with "Used 2 of 2 today".

### Network (try each in a session of the named mode)
- [ ] Journal: `reddit.com` doesn't load. `www.google.com` doesn't load. Your doc does.
- [ ] Claude: claude.ai, github.com and pypi.org load. `youtube.com` doesn't.
- [ ] In Terminal: `curl -sI https://example.com` fails. `curl -sI https://github.com` works.
- [ ] In Terminal: `dig @8.8.8.8 example.com` times out (other DNS servers are blocked).
- [ ] In Terminal: `curl -sI https://1.1.1.1` fails (DNS-over-HTTPS IPs are blocked).
- [ ] Set Chrome's **Settings → Privacy → Use secure DNS** to Cloudflare. With the profile installed this is
      greyed out; either way, blocked sites stay blocked.
- [ ] Locked (no session): nothing loads at all.
- [ ] `sudo networksetup -setdnsservers Wi-Fi 8.8.8.8` (SSH). Within about 5 s it's back to 127.0.0.1 (check with
      `networksetup -getdnsservers Wi-Fi`). While it was changed, nothing resolved.
- [ ] `sudo pfctl -d` (SSH). Within about 5 s, `sudo pfctl -s info` shows Enabled again.
- [ ] Switch networks. In a VM: shut down, change the network mode in UTM's settings, start again. It stays locked.

### Apps
- [ ] Journal session: open Notes or Terminal through Spotlight. It gets quit.
- [ ] Any session: open Safari. It always gets quit.
- [ ] From Terminal in Claude mode, `open -a Safari` gets quit too.
- [ ] Quit Chrome and start it from Terminal with `--proxy-server=1.2.3.4:80`:
      `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --proxy-server=1.2.3.4:80`. It gets quit.
- [ ] Install a VPN app (e.g. the free Proton VPN). It gets quit, and if it ever runs, it can't connect.

### Timer and extension
- [ ] 2 minutes before the end, the panel turns orange and plays a sound.
- [ ] **+10 min…** makes you wait 60 s and then asks for a typed reason. After that it works once and only once.
- [ ] **End session → End now** ends the session at once. Apps quit, the lock screen returns.
- [ ] When time runs out, the same happens by itself.
- [ ] Reboot during a session. After login the session continues with the right remaining time (or the screen is
      locked if the time ran out meanwhile).

### Dev tools
- [ ] `sudo intentmode learn start journal`, use the doc for a minute, then `sudo intentmode learn stop`. You get a
      list of domains. Try `--apply` and check that `config.json` now contains them.
- [ ] `sudo intentmode emergency-off`: the lock screen disappears, websites work, and
      `networksetup -getdnsservers Wi-Fi` shows your old setting. After a reboot it's still off.
      `sudo intentmode emergency-off --undo` turns it back on.
- [ ] **Emergency off…** on the lock screen with a wrong password refuses; with the right admin password it works.

### Updates and rollback
- [ ] Change something visible (e.g. the "What are you here for?" text in `Sources/IntentScreen/Views.swift`),
      set `VERSION` to `0.1.1` and run `scripts/build.sh "test update"`. Then run
      `intentmode update propose build/IntentMode-0.1.1.tar.gz`. The screen restarts with the change, and
      `intentmode update list` shows 0.1.1 as running and known-good.
- [ ] `intentmode update rollback` brings 0.1.0 back immediately.
- [ ] Propose the same version again: refused ("not newer").
- [ ] Edit any file inside a built package after signing and propose it: refused ("modified after signing").
- [ ] Optional, to test automatic rollback: make `intentmoded` exit right away in a 0.1.2 build (add `exit(1)` at
      the top of `Sources/intentmoded/main.swift`). After proposing it, `guard.log` shows a rollback within a few
      seconds.

### Uninstall
- [ ] `sudo "/Library/Application Support/IntentMode/uninstall.sh"` leaves a normal Mac. Websites work, DNS is back
      to normal, and nothing from Intent Mode runs after a reboot.

When everything passes in the VM, the same steps install it on your real Mac. Tell me what failed (with
`daemon.log`) and I'll fix it before Phase 2.
