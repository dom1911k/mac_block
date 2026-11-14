# Intent Mode

A default-locked focus system for macOS. The Mac stays **locked**: only a full-screen "What are you here for?"
screen is shown. You pick a mode, type your intent, and for a fixed time you get only that mode's apps and websites.
Everything else is unreachable. This works on an **allowlist**, not a blocklist.

Status: **Phase 1 (core)**, a dev build. `learn` and `emergency-off` are included.

## How it works

```
┌──────────────────────────┐   Unix socket (JSON)  ┌───────────────────────────────────────────┐
│ IntentScreen.app (user)  │ ────────────────────▶ │ intentmoded (root, LaunchDaemon)          │
│  kiosk screen / timer    │    /var/run/          │  state: locked / session / learn          │
│  only *asks*             │    intentmode.sock    │  timers, daily limits, extensions         │
└──────────────────────────┘                       │  ├─ DNS resolver 127.0.0.1:53             │
┌──────────────────────────┐                       │  │    blocklist → allowlist → upstream    │
│ intentmode (CLI)         │ ────────────────────▶ │  │    (1.1.1.3 / 1.0.0.3 family filter)   │
└──────────────────────────┘                       │  ├─ pf anchor com.apple/000.intentmode    │
                                                   │  │    default-deny outbound; resolved IPs │
                    launchd                        │  │    go into table <im_allow>            │
                       │                           │  ├─ DNS-settings enforcer (networksetup)  │
                       ▼                           │  ├─ app watcher (quits disallowed apps)   │
              intentguard (root) ─── starts ─────▶ │  └─ updater (signed packages, rollback)   │
              rolls back failed updates            └───────────────────────────────────────────┘
```

* **Allowlist DNS.** Every DNS query goes to our resolver. Names on the adult blocklist (Phase 2) get NXDOMAIN
  in every mode. So do names the current mode doesn't list. Allowed names are forwarded to Cloudflare's
  1.1.1.3, which filters malware and adult content as a second layer.
* **Default-deny firewall.** pf blocks all outgoing traffic except to IPs the resolver just handed out for allowed
  names. Hard-coded IPs, other DNS servers, DNS-over-HTTPS/TLS, VPNs, new Wi-Fi networks and USB tethering
  can't get around it, because the rules apply to every interface.
* **App watcher.** Every 0.5 s the daemon checks the logged-in user's apps. Anything that isn't in the current
  mode, isn't a macOS system component and isn't the intent screen gets quit (SIGTERM, then SIGKILL after 5 s).
  Browsers other than Chrome and VPN apps are always quit. Apps are matched by bundle ID plus, optionally, their
  code-signing team, so a renamed copy or a home-made "Chrome" doesn't pass.
* **Fails closed.** If the daemon crashes, the pf rules stay loaded and DNS still points at 127.0.0.1, so nothing
  resolves or connects until launchd restarts it.
* **The intent screen** enforces nothing. It's a kiosk window (no Dock, menu bar, ⌘-Tab, Force Quit or logout
  dialog). A LaunchAgent relaunches it if it's quit or killed. During a session it shrinks to a small timer in the
  top-right corner.

### Files

| Where | What |
|---|---|
| `/Library/Application Support/IntentMode/config.json` | Your config (root-owned, human-readable JSON) |
| `…/daemon.log` | What the daemon did and why (apps quit, policy changes, errors) |
| `…/sessions.jsonl` | One line per session start/end/extension (becomes SQLite in Phase 3) |
| `…/state.json` | Today's usage and the running session (survives restarts) |
| `…/versions/<v>/` + `current` symlink | Installed builds (last 3 kept) |
| `…/dns-backup.txt` | Your original DNS settings, restored by emergency-off/uninstall |
| `/Library/LaunchDaemons/com.intentmode.daemon.plist` | Starts `intentguard` as root at boot |
| `/Library/LaunchAgents/com.intentmode.screen.plist` | Starts the intent screen at login |
| `/usr/local/bin/intentmode` | The CLI |

### Source layout

```
Sources/IntentCore/    shared: config, domain matching, DNS wire format, pf rules text, IPC, update packages
Sources/intentmoded/   the daemon (Daemon.swift is the state machine)
Sources/intentguard/   launcher + automatic rollback
Sources/intentmode/    CLI
Sources/IntentScreen/  the kiosk app (AppKit + SwiftUI)
Resources/             default config, launchd plists, Chrome profile, emergency-off/uninstall scripts
scripts/               build.sh, install.sh
```

## Build

You only need the Xcode Command Line Tools, not full Xcode.

```bash
xcode-select --install
```

```bash
git clone https://github.com/dom1911k/mac_block.git
```

```bash
cd mac_block
```

```bash
scripts/build.sh "first build"
```

This produces `build/IntentMode-<version>/` and a `.tar.gz` of it. The first build also creates your
update-signing key in `~/.intentmode/signing_key`. Keep it: updates must be signed with it.

Building installs nothing. It's safe on your real Mac.

## Try it (easiest)

Double-click **Try Intent Mode.command**. It installs Apple's developer tools if needed, builds, and starts a
**test** on your normal Mac that switches itself off after 10–60 minutes, on restart, or with the
**Stop test now** button. Step-by-step guide: [docs/EASY-TEST.md](docs/EASY-TEST.md).
To remove everything: double-click **Stop Intent Mode.command**.

(The more thorough VM-based checklist is in [docs/PHASE1-TESTING.md](docs/PHASE1-TESTING.md).)

## Install (for real)

```bash
sudo build/IntentMode-0.1.0/install.sh
```

The installer asks you to type `INSTALL`, then copies files, installs the two launchd jobs and starts them.
The Mac locks immediately.

Then install the Chrome policies: double-click `/Users/Shared/IntentMode/IntentMode-Chrome.mobileconfig` and
approve it in **System Settings → General → Device Management**. Check `chrome://policy` in a session.
*Note:* that profile blocks **all** Chrome extensions, including ones you already have. To keep one, add its ID to
`ExtensionInstallAllowlist` in the profile and reinstall the profile.

## Turning it off

| Situation | What to do |
|---|---|
| You're in a session that allows Terminal (Claude mode) | `sudo intentmode emergency-off` |
| You're on the locked screen | **Emergency off…** (bottom right, dev builds only), then your admin name and password |
| The screen is broken | SSH in from another computer (turn on **Remote Login** first, at least in the VM), then `sudo intentmode emergency-off` |
| Nothing works at all | Boot into Recovery (hold the power button), open Terminal and run `rm "/Volumes/Macintosh HD/Library/LaunchDaemons/com.intentmode.daemon.plist"`. Unlock the disk in Disk Utility first if FileVault asks. After a normal boot, run `sudo "/Library/Application Support/IntentMode/emergency-off.sh"` to restore DNS. |

`emergency-off` stops the daemon and screen and **keeps them off across reboots**. It also removes the pf rules
and restores your DNS. To turn everything back on:

```bash
sudo intentmode emergency-off --undo
```

## Uninstall

```bash
sudo "/Library/Application Support/IntentMode/uninstall.sh"
```

This runs emergency-off, removes all files and launchd jobs, and offers to keep a copy of your config and logs.
Remove the Chrome profile yourself in System Settings → General → Device Management.

## Editing the config

```bash
sudo nano "/Library/Application Support/IntentMode/config.json"
```

The daemon reloads it within 5 seconds. If the file has an error, the daemon keeps the previous version. The
intent screen then shows a notice and the details are in `daemon.log`. You can also reload by hand:
`sudo intentmode reload`.

**Domain entries**

| Entry | Means |
|---|---|
| `claude.ai` | claude.ai and every subdomain (`api.claude.ai`, …) |
| `=docs.google.com` | exactly docs.google.com, nothing else |
| `@google_signin` | everything in `domain_groups.google_signin` |

Use `=` for Google: `google.com` without `=` would open Search, Images, Maps and so on.

**Finding the domains a mode needs** (dev builds):

```bash
sudo intentmode learn start journal
```

This allows everything (except the adult filter) and records every name looked up. Use the mode's apps normally,
then:

```bash
sudo intentmode learn stop --apply
```

That adds the new domains to the mode. Without `--apply` it only lists them, and a copy is always saved in
`…/learned/`. Review the list, since some entries will be ads or tracking you don't need.

**Apps** are listed per mode by bundle ID. `team_id` pins the code signature: `apple` for Apple apps, otherwise
the 10-character developer team. To get both for an app:

```bash
intentmode inspect-app /Applications/Claude.app
```

Other keys: `intent_min_words`, `warning_seconds`, `extension_*`, `daily_limit`/`minutes` per mode,
`flags.claude_mode_allow_google_search`, `system_path_prefixes` (which macOS components are always allowed),
`always_allowed_bundle_ids`, `never_allowed_bundle_ids`, `chrome_forbidden_flags`, `doh_block_ips`, `exempt_users`
(accounts that get no kiosk and no app watcher, such as the separate admin account in Phase 4).

## Updating (fixing bugs from inside Intent Mode)

1. In a Claude session (Terminal is allowed), change the code and bump `VERSION`.
2. Run `scripts/build.sh "what changed"`.
3. Run `intentmode update propose build/IntentMode-<v>.tar.gz`. No admin password is needed.

The daemon copies the build into a root-owned folder, checks the Ed25519 signature and every file hash, requires a
higher version, and runs the new build's self-test against your current config. Then it switches to the new build
and restarts. If the new daemon doesn't report healthy within 2 minutes, `intentguard` switches back on its own.
State (usage, running session, logs) is kept.

`intentmode update rollback` goes back to the previous known-good version instantly. `intentmode update list`
shows what's installed. Phases 1–3 apply updates immediately; Phase 4 adds the 24-hour delay.

## Known leaks and limits

* **Shared CDN IPs (accepted).** If a blocked site shares an IP with an allowed one (Cloudflare, Google front
  ends), a program that connects by IP or fakes DNS can reach it. Chrome started with `--host-resolver-rules` or
  `--proxy-server` is quit for this reason. `curl --resolve` from Terminal in Claude mode remains possible.
* **The first seconds after boot**, before the daemon loads its rules. Nobody is logged in yet.
* **Captive portals** (hotel and train Wi-Fi login pages) don't work while locked. Add the portal's domain to
  `session_allowed_domains`, or use `learn`.
* **Apple services** (iCloud, App Store, software updates) don't work while locked or in narrow modes. Phase 2's
  open session covers updates.
* **Phases 1–3 aren't tamper-proof.** You're an admin, so `sudo` undoes everything. That changes in Phase 4
  (standard account and break-glass password).
* **The kiosk is cosmetic.** Trackpad gestures, Spotlight and hot corners may still work on the locked screen.
  Anything they open gets quit within a second.
* **Join Wi-Fi…** shows the menu bar for 2 minutes. This replaces the in-app Wi-Fi picker from the plan:
  listing networks from an app needs Location permission on recent macOS, and the system menu also handles
  hidden networks and enterprise logins.
