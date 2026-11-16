import Foundation
import Darwin
import Security
import IntentCore

// intentmode — command-line tool for Intent Mode.

let usage = """
intentmode \(BuildInfo.version)\(BuildInfo.isDevBuild ? " (dev build)" : "")

Everyday:
  intentmode status                       Show the current state and today's usage
  intentmode start <mode> <intent…>       Start a session (the intent screen does this normally)
  intentmode end [reason…]                End the running session early
  intentmode week                         Usage overview for this week

Updates:
  intentmode update propose <path>        Install a new build (folder or .tar.gz from scripts/build.sh)
  intentmode update rollback              Go back to the previous known-good version (instant)
  intentmode update list                  Show installed versions

Settings and lock-down:
  intentmode config edit                  Edit the settings (nano); loosening changes wait 24 h in lock-down
  intentmode pending [cancel <id>]        Show / cancel changes that are waiting
  sudo intentmode lockdown enable         Turn on lock-down (Phase 4)
  intentmode lockdown status | disable | cancel | keep

Admin (sudo):
  sudo intentmode reload                  Reload config.json now (it also reloads by itself within 5 s)
  sudo intentmode learn start <mode>      Dev builds: allow everything and record visited domains
  sudo intentmode learn stop [--apply]    Dev builds: show recorded domains (--apply adds them to the mode)
  sudo intentmode emergency-off           Dev builds: remove ALL enforcement (pf, DNS, agents) until re-enabled
  sudo intentmode emergency-off --undo    Turn enforcement back on after an emergency-off

Building:
  intentmode keygen                       Create your update-signing key in ~/.intentmode/
  intentmode sign <dir> --key <file> --version <v> [--changelog <text>]
  intentmode verify <dir> [--pubkey <file>]
  intentmode inspect-app <path.app>       Show an app's bundle ID and signing team (for config.json)
  intentmode version
"""

var args = Array(CommandLine.arguments.dropFirst())

func die(_ m: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((m + "\n").utf8))
    exit(code)
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

@discardableResult
func call(_ req: IPCRequest, timeout: Int = 15) -> IPCResponse {
    let r: IPCResponse
    do { r = try IPCClient.send(req, timeoutSeconds: timeout) } catch { die("\(error)") }
    if let m = r.message { print(m) }
    for l in r.lines ?? [] { print("  \(l)") }
    if !r.ok { die("Error: \(r.error ?? "unknown error")") }
    return r
}

@discardableResult
func run_open(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = args
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus
}

func formatDuration(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

guard let cmd = args.first else { print(usage); exit(0) }

switch cmd {
case "version", "--version":
    print(BuildInfo.version + (BuildInfo.isDevBuild ? " (dev build)" : ""))

case "help", "--help", "-h":
    print(usage)

case "status":
    let r = call(IPCRequest(cmd: "status"))
    guard let s = r.status else { break }
    print("Intent Mode \(s.version)\(s.devBuild ? " (dev build)" : "")")
    switch s.state {
    case "locked": print("State: LOCKED")
    default:
        print("State: \(s.state.uppercased()) — \(s.modeName ?? "?") — \(formatDuration(s.remainingSeconds ?? 0)) left")
        if let i = s.intent { print("Intent: \(i)") }
        print("Extension: \(s.extensionState)")
    }
    if let n = s.notice { print("Notice: \(n)") }
    print("\nModes today:")
    for m in s.modes {
        var limit = m.dailyLimit.map { "\(m.usedToday)/\($0)" } ?? "\(m.usedToday)/∞"
        if let w = m.weeklyLimit { limit += ", week \(m.usedThisWeek)/\(w)" }
        print("  \(m.id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(m.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(m.minutes) min  used \(limit)\(m.available ? "" : "  — \(m.unavailableReason ?? "unavailable")")")
    }

case "start":
    guard args.count >= 3 else { die("usage: intentmode start <mode> <intent…>") }
    let r = call(IPCRequest(cmd: "start", mode: args[1], intent: args[2...].joined(separator: " ")))
    if let wait = r.waitSeconds {
        print("Waiting \(wait) s (press Ctrl-C to cancel)…")
        sleep(UInt32(wait))
        call(IPCRequest(cmd: "start_confirm"))
    }

case "lockdown":
    let sub = args.count > 1 ? args[1] : "status"
    switch sub {
    case "enable":
        if getuid() != 0 { die("Run this with sudo: sudo intentmode lockdown enable") }
        let forUser = option("--user")
        if !args.contains("--yes") {
            print("""

              LOCK-DOWN
              ─────────
              • sudo stops working for your account (no Terminal way to switch Intent Mode off)
              • Emergency off and learn are disabled
              • Loosening settings changes and updates wait 24 hours (tightening applies at once)
              • ONE-TIME escape: "Turn off lock-down" on the lock screen takes effect after 24 hours.
                It's gone for good once used, or once you confirm you'll keep using Intent Mode.

            """)
            print("Type LOCK DOWN to continue: ", terminator: "")
            guard readLine() == "LOCK DOWN" else { die("Cancelled.") }
        }
        call(IPCRequest(cmd: "lockdown_enable", username: forUser))
    case "status":
        let r = call(IPCRequest(cmd: "status"))
        guard let s = r.status else { break }
        if !s.lockdownActive { print("Lock-down: off") } else {
            print("Lock-down: ON")
            if let d = s.lockdownDisableIn { print("Turning off in \(d / 3600) h \((d / 60) % 60) min") }
            else { print("One-time turn-off: \(s.lockdownEscapeAvailable ? "available" : "gone")") }
        }
        for p in s.pending { print("Pending (\(p.dueIn / 3600) h \((p.dueIn / 60) % 60) min): \(p.description)   [id \(p.id)]") }
    case "disable":
        call(IPCRequest(cmd: "lockdown_disable_request"))
    case "cancel":
        call(IPCRequest(cmd: "lockdown_disable_cancel"))
    case "keep":
        print("This removes the one-time turn-off for good. Type exactly:\n  I will keep using Intent Mode as intended\n> ", terminator: "")
        call(IPCRequest(cmd: "lockdown_keep", reason: readLine() ?? ""))
    default:
        die("usage: intentmode lockdown status | sudo intentmode lockdown enable | disable | cancel | keep")
    }

case "config":
    let sub = args.count > 1 ? args[1] : ""
    switch sub {
    case "edit":
        // Copy the live config to your home folder, open it in TextEdit, then propose it.
        let copy = (NSHomeDirectory() as NSString).appendingPathComponent("IntentMode-settings.json")
        do {
            if FileManager.default.fileExists(atPath: copy) { try FileManager.default.removeItem(atPath: copy) }
            try FileManager.default.copyItem(atPath: Paths.config, toPath: copy)
        } catch { die("Couldn't copy the settings: \(error)") }
        // nano runs inside the Terminal window (TextEdit would be closed by the app watcher).
        print("""
            Opening the settings in the nano editor, right here in Terminal.
              • Move with the arrow keys, type to change things.
              • Save: Control-O, then Return.   Quit: Control-X.

            Press Return to start…
            """, terminator: "")
        _ = readLine()
        let editor = Process()
        editor.executableURL = URL(fileURLWithPath: "/usr/bin/nano")
        editor.arguments = [copy]
        editor.standardInput = FileHandle.standardInput
        editor.standardOutput = FileHandle.standardOutput
        editor.standardError = FileHandle.standardError
        do { try editor.run(); editor.waitUntilExit() } catch { die("Couldn't start nano: \(error)") }
        call(IPCRequest(cmd: "config_propose", path: copy))
    case "propose":
        guard args.count >= 3 else { die("usage: intentmode config propose <file>") }
        call(IPCRequest(cmd: "config_propose", path: URL(fileURLWithPath: args[2]).standardizedFileURL.path))
    default:
        die("usage: intentmode config edit | config propose <file>")
    }

case "pending":
    if args.count >= 3 && args[1] == "cancel" {
        call(IPCRequest(cmd: "pending_cancel", noteId: args[2]))
    } else {
        let r = call(IPCRequest(cmd: "status"))
        let items = r.status?.pending ?? []
        if items.isEmpty { print("Nothing pending.") }
        for p in items { print("\(p.dueIn / 3600) h \((p.dueIn / 60) % 60) min — \(p.description)   (cancel: intentmode pending cancel \(p.id))") }
    }

case "week":
    let r = call(IPCRequest(cmd: "stats"))
    guard let s = r.stats else { break }
    print("This week: \(s.totalMinutes) min in \(s.sessionCount) sessions (last week: \(s.lastWeekMinutes) min)")
    print("Per day (Mon–Sun): \(s.perDayMinutes.map(String.init).joined(separator: " "))")
    print("Open sessions: \(s.openSessionsUsed)\(s.openSessionsLimit.map { "/\($0)" } ?? "")  ·  extended: \(s.extensions)  ·  ended early: \(s.endedEarly)")
    for m in s.perMode { print("  \(m.name): \(m.sessions)× \(m.minutes) min") }
    for x in s.sessions { print("  - \(x.modeName), \(x.minutes) min: \(x.intent)") }

case "end":
    call(IPCRequest(cmd: "end", reason: args.count > 1 ? args[1...].joined(separator: " ") : "ended from the command line"))

case "reload":
    call(IPCRequest(cmd: "reload"))

case "learn":
    guard args.count >= 2 else { die("usage: sudo intentmode learn start <mode> | stop [--apply]") }
    if getuid() != 0 { die("Run this with sudo: sudo intentmode \(args.joined(separator: " "))") }
    switch args[1] {
    case "start":
        guard args.count >= 3 else { die("usage: sudo intentmode learn start <mode>") }
        call(IPCRequest(cmd: "learn_start", mode: args[2]))
    case "stop":
        call(IPCRequest(cmd: "learn_stop", apply: args.contains("--apply")))
    default:
        die("usage: sudo intentmode learn start <mode> | stop [--apply]")
    }

case "emergency-off":
    guard BuildInfo.isDevBuild else { die("emergency-off is not part of release builds.") }
    if getuid() != 0 { die("Run this with sudo: sudo intentmode emergency-off") }
    var script = Paths.emergencyScript
    if !FileManager.default.fileExists(atPath: script) {
        // Fall back to the copy next to this binary (…/versions/<v>/bin/intentmode → …/Resources/).
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        script = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/emergency-off.sh").path
    }
    let extra = args.contains("--undo") ? ["--undo"] : []
    let argv: [UnsafeMutablePointer<CChar>?] = (["/bin/bash", script] + extra).map { strdup($0) } + [nil]
    execv("/bin/bash", argv)
    die("could not run \(script)")

case "update":
    guard args.count >= 2 else { die("usage: intentmode update propose <path> | rollback | list") }
    switch args[1] {
    case "propose":
        guard args.count >= 3 else { die("usage: intentmode update propose <path-to-build>") }
        let path = URL(fileURLWithPath: args[2]).standardizedFileURL.path
        print("Checking and installing \(path) … (this can take up to a minute)")
        call(IPCRequest(cmd: "update_propose", path: path), timeout: 240)
    case "rollback":
        call(IPCRequest(cmd: "update_rollback"))
    case "list":
        call(IPCRequest(cmd: "update_list"))
    default:
        die("usage: intentmode update propose <path> | rollback | list")
    }

case "keygen":
    let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".intentmode")
    let priv = dir + "/signing_key"
    if FileManager.default.fileExists(atPath: priv) && !args.contains("--force") {
        die("\(priv) already exists. Use --force to replace it (then reinstall, since the daemon trusts the old public key).")
    }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let (k, pub) = PackageTool.generateKeyPair()
    do {
        try FileUtil.writeAtomically(Data(k.base64EncodedString().utf8), to: priv, mode: 0o600)
        try FileUtil.writeAtomically(Data(pub.base64EncodedString().utf8), to: priv + ".pub", mode: 0o644)
    } catch { die("\(error)") }
    print("Created \(priv) (keep it private) and \(priv).pub")

case "sign":
    guard args.count >= 2, let keyPath = option("--key"), let version = option("--version") else {
        die("usage: intentmode sign <dir> --key <file> --version <v> [--changelog <text>]")
    }
    do {
        let key = try PackageTool.loadKey(keyPath)
        try PackageTool.sign(root: args[1], version: version, changelog: option("--changelog") ?? "", privateKey: key)
        print("Signed \(args[1]) as version \(version)")
    } catch { die("\(error)") }

case "verify":
    guard args.count >= 2 else { die("usage: intentmode verify <dir> [--pubkey <file>]") }
    let pubPath = option("--pubkey") ?? Paths.updatePublicKey
    do {
        let m = try PackageTool.verify(root: args[1], publicKey: try PackageTool.loadKey(pubPath))
        print("OK: version \(m.version), \(m.files.count) files, signed \(m.created)")
    } catch { die("FAILED: \(error)") }

case "inspect-app":
    guard args.count >= 2 else { die("usage: intentmode inspect-app /Applications/Foo.app") }
    let path = args[1]
    let bid = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String ?? "?"
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
        die("cannot read the code signature of \(path)")
    }
    var info: CFDictionary?
    SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
    let dict = info as? [String: Any] ?? [:]
    let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
    var req: SecRequirement?
    SecRequirementCreateWithString("anchor apple" as CFString, [], &req)
    let isApple = req.map { SecStaticCodeCheckValidity(code, [], $0) == errSecSuccess } ?? false
    print("bundle_id: \(bid)")
    print("team_id:   \(isApple ? "apple" : (team ?? "(unsigned or ad-hoc — leave team_id out)"))")
    print("\nconfig.json entry:\n  { \"bundle_id\": \"\(bid)\"\(isApple || team != nil ? ", \"team_id\": \"\(isApple ? "apple" : team!)\"" : "") }")

default:
    die("unknown command '\(cmd)'\n\n\(usage)")
}
