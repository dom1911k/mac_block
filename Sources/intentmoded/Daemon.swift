import Foundation
import Darwin
import OpenDirectory
import IntentCore

/// The single source of truth. All state changes run on `queue`.
///
/// States: locked → session(mode, ends_at) → locked, plus learn(mode) in dev builds.
/// Fails closed: if this process dies, pf rules and the DNS setting stay in place
/// (nothing resolves, nothing connects) until launchd restarts it.
final class Daemon {
    private let queue = DispatchQueue(label: "intentmode.daemon")

    private enum Phase {
        case locked
        case session
        case learn(modeId: String, until: Date)
    }

    private var config: IntentConfig
    private var configMTime: Date?
    private var notice: String?
    private var blocklist = DomainMatcher()
    private var pstate = PersistentState.load()
    private var phase: Phase = .locked
    private var generation = 0
    /// Monotonic time (seconds since boot, paused during sleep) when +10 was requested.
    private var extensionRequestedAt: TimeInterval?
    private var tickCount = 0
    /// Set during a test install (test-mode.json). Everything is removed when it passes.
    private let testEndsAt: Date? = TestMode.load().map { Date(timeIntervalSince1970: $0.endsAt) }
    private var testStopping = false
    /// A start waiting out its mode's start_delay_seconds (monotonic `readyAt`).
    private struct PendingStart { let modeId: String; let intent: String; let readyAt: TimeInterval; let uid: uid_t }
    private var pendingStart: PendingStart?
    private var timer: DispatchSourceTimer?

    private let box: PolicyBox
    private let pf: PFManager
    private let dns: DNSServer
    private let dnsSettings = DNSSettingsEnforcer()
    private let apps: AppWatcher
    private let updater = Updater()
    private var control: ControlServer!

    init() {
        let fm = FileManager.default
        for dir in [Paths.base, Paths.versions, Paths.staging, Paths.learned] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        var loaded: IntentConfig
        var notice: String?
        do {
            loaded = try IntentConfig.load(path: Paths.config)
            try? fm.removeItem(atPath: Paths.configLastGood)
            try? fm.copyItem(atPath: Paths.config, toPath: Paths.configLastGood)
        } catch {
            Log.error("\(error)")
            if let last = try? IntentConfig.load(path: Paths.configLastGood) {
                loaded = last
                notice = "config.json has an error — using the last good version. See daemon.log."
            } else {
                loaded = IntentConfig() // no modes: stays locked (fail closed)
                notice = "config.json could not be loaded — no modes available. See daemon.log."
            }
        }
        config = loaded
        self.notice = notice
        configMTime = FileUtil.mtime(Paths.config)
        let locked = Policy(kind: .locked, generation: 0, allow: DomainMatcher(entries: loaded.expand(loaded.lockedAllowedDomains)),
                            block: DomainMatcher(), allowAll: false, apps: [])
        box = PolicyBox(locked)
        pf = PFManager(config: loaded)
        dns = DNSServer(box: box, pf: pf, upstream: loaded.upstreamDns)
        apps = AppWatcher(config: Self.appsConfig(loaded, testMode: TestMode.load() != nil))
        blocklist = Self.loadBlocklist(loaded)
        control = ControlServer { [unowned self] req, uid in self.handle(req, uid: uid) }
    }

    // MARK: lifecycle

    func start() {
        Log.info("intentmoded \(BuildInfo.version)\(BuildInfo.isDevBuild ? " (dev build)" : "") starting")
        SessionLog.write(["event": "daemon_start", "version": BuildInfo.version])
        pf.onTableLost = { flushDNSCache() }
        pf.setup()
        dnsSettings.start()
        startDNS()
        do { try control.start() } catch { Log.error("\(error)") }

        queue.sync {
            if let s = pstate.session {
                if s.endsAt > Date(), config.mode(s.modeId) != nil {
                    phase = .session
                    Log.info("resuming \(s.modeId) session until \(s.endsAt)")
                } else {
                    SessionLog.write(["event": "session_end", "mode": s.modeId, "ended_early": false, "note": "ended while daemon was not running"])
                    pstate.session = nil
                    pstate.save()
                }
            }
            applyPolicy(reason: "startup")
        }
        apps.start()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        // Tell intentguard we're healthy once everything has been up for a few seconds.
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            try? FileUtil.writeAtomically(Data(BuildInfo.version.utf8), to: Paths.health, mode: 0o644)
            self?.updater.prune()
        }
    }

    private func startDNS() {
        do { try dns.start() } catch {
            Log.error("\(error) — retrying in 5 s (nothing resolves meanwhile)")
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in self?.startDNS() }
        }
    }

    /// SIGTERM: save and exit, leaving pf and DNS in place (fail closed).
    func shutdown() {
        queue.sync { pstate.save() }
        Log.info("intentmoded stopping (enforcement stays in place)")
    }

    /// In test mode Terminal is never quit, so there is always a way out.
    private static func appsConfig(_ c: IntentConfig, testMode: Bool) -> IntentConfig {
        guard testMode else { return c }
        var copy = c
        copy.alwaysAllowedBundleIds.append("com.apple.Terminal")
        return copy
    }

    private func tick() {
        tickCount += 1
        let now = Date()
        if let t = testEndsAt, now >= t, !testStopping {
            Log.warn("test time is over; removing Intent Mode")
            _ = stopTest()
        }
        switch phase {
        case .session:
            if let s = pstate.session, now >= s.endsAt { endSession(early: false, reason: "time is up") }
        case .learn(_, let until):
            if now >= until { _ = stopLearn(apply: false) }
        case .locked:
            if let p = pendingStart, ProcessInfo.processInfo.systemUptime > p.readyAt + 120 {
                Log.info("pending start of \(p.modeId) expired (not confirmed)")
                pendingStart = nil
            }
        }
        if tickCount % 5 == 0 {
            reloadConfigIfChanged()
            pf.watchdog()
        }
        if tickCount % 30 == 0 { pf.expire() }
    }

    // MARK: policy

    private static func loadBlocklist(_ c: IntentConfig) -> DomainMatcher {
        var m = DomainMatcher()
        for f in c.blocklistFiles {
            let path = f.hasPrefix("/") ? f : Paths.base + "/" + f
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                Log.warn("blocklist file missing: \(path)")
                continue
            }
            for e in DomainMatcher.entries(fromListFile: text) { m.add(e) }
        }
        if !m.isEmpty { Log.info("blocklist loaded: \(m.count) entries") }
        return m
    }

    private func makePolicy(generation g: Int) -> Policy {
        switch phase {
        case .locked:
            return Policy(kind: .locked, generation: g, allow: DomainMatcher(entries: config.expand(config.lockedAllowedDomains)),
                          block: blocklist, allowAll: false, apps: [])
        case .session:
            let mode = pstate.session.flatMap { config.mode($0.modeId) }
            if let mode, mode.isOpenWeb {
                // Open web: everything except the adult blocklist and the mode's blocked_domains.
                var block = blocklist
                for e in config.blockedDomains(for: mode) { block.add(e) }
                return Policy(kind: .session, generation: g, allow: DomainMatcher(entries: ["*"]),
                              block: block, allowAll: true, apps: mode.apps)
            }
            return Policy(kind: .session, generation: g, allow: DomainMatcher(entries: mode.map { config.domains(for: $0) } ?? []),
                          block: blocklist, allowAll: false, apps: mode?.apps ?? [])
        case .learn(let id, _):
            return Policy(kind: .learn, generation: g, allow: DomainMatcher(entries: ["*"]),
                          block: blocklist, allowAll: true, apps: config.mode(id)?.apps ?? [])
        }
    }

    private var policyLabel: String {
        switch phase {
        case .locked: return "locked"
        case .session: return "session:\(pstate.session?.modeId ?? "?")"
        case .learn(let id, _): return "learn:\(id)"
        }
    }

    /// Full switch: new generation, pf table emptied, connections cut, DNS cache flushed, apps re-checked.
    private func applyPolicy(reason: String) {
        generation += 1
        let p = makePolicy(generation: generation)
        pf.reset(generation: generation)   // before publishing, so in-flight answers for the old policy are dropped
        box.set(p)
        flushDNSCache()
        apps.setPolicy(AppPolicy(apps: p.apps, generation: generation, label: policyLabel))
        Log.info("policy → \(policyLabel) (\(reason))")
    }

    /// Config edit during a session: update lists without cutting connections.
    private func refreshPolicyInPlace() {
        let p = makePolicy(generation: generation)
        box.set(p)
        apps.setPolicy(AppPolicy(apps: p.apps, generation: generation, label: policyLabel)) // setPolicy re-checks every app
    }

    private func reloadConfigIfChanged(force: Bool = false) {
        let m = FileUtil.mtime(Paths.config)
        guard force || m != configMTime else { return }
        configMTime = m
        do {
            let c = try IntentConfig.load(path: Paths.config)
            config = c
            notice = nil
            blocklist = Self.loadBlocklist(c)
            try? FileManager.default.removeItem(atPath: Paths.configLastGood)
            try? FileManager.default.copyItem(atPath: Paths.config, toPath: Paths.configLastGood)
            pf.updateConfig(c)
            dns.setUpstream(c.upstreamDns)
            apps.updateConfig(Self.appsConfig(c, testMode: testEndsAt != nil))
            if case .session = phase, let s = pstate.session, c.mode(s.modeId) == nil {
                endSession(early: true, reason: "mode was removed from config")
            } else {
                refreshPolicyInPlace()
            }
            Log.info("config reloaded")
        } catch {
            notice = "config.json has an error — still using the previous version. See daemon.log."
            Log.error("config reload failed, keeping previous config: \(error)")
        }
    }

    // MARK: requests

    func handle(_ r: IPCRequest, uid: uid_t) -> IPCResponse {
        let t0 = Date()
        var waited = 0.0
        let resp: IPCResponse = queue.sync {
            waited = Date().timeIntervalSince(t0)
            return handleOnQueue(r, uid: uid)
        }
        let took = Date().timeIntervalSince(t0)
        if r.cmd != "status" && r.cmd != "app_launched" {
            Log.info("request \(r.cmd)\(r.mode.map { " \($0)" } ?? "") from uid \(uid) → \(resp.ok ? "ok" : "failed: \(resp.error ?? "")") (\(String(format: "%.2f", took)) s)")
        } else if took > 1 {
            Log.warn("slow \(r.cmd) request: waited \(String(format: "%.2f", waited)) s, total \(String(format: "%.2f", took)) s")
        }
        return resp
    }

    private func handleOnQueue(_ r: IPCRequest, uid: uid_t) -> IPCResponse {
        switch r.cmd {
        case "ping":
            return .success("pong")
        case "status":
            return IPCResponse(ok: true, status: status(uid: uid))
        case "start":
            return start(modeId: r.mode ?? "", intent: r.intent ?? "", uid: uid)
        case "start_confirm":
            return confirmStart(uid: uid)
        case "start_cancel":
            if let p = pendingStart { Log.info("start of \(p.modeId) cancelled during the pause") }
            pendingStart = nil
            return .success("Cancelled.")
        case "end":
            guard case .session = phase else { return .fail("No session is running.") }
            endSession(early: true, reason: r.reason?.isEmpty == false ? r.reason! : "ended early")
            return .success("Session ended.")
        case "extend_request":
            return extendRequest()
        case "extend_confirm":
            return extendConfirm(reason: r.reason ?? "")
        case "app_launched":
            if let pid = r.pid { apps.hint(pid: pid) }
            return .success()
        case "reload":
            guard uid == 0 else { return .fail("Run this with sudo.") }
            reloadConfigIfChanged(force: true)
            return notice == nil ? .success("Config reloaded.") : .fail(notice!)
        case "learn_start":
            guard BuildInfo.isDevBuild else { return .fail("learn is only available in dev builds.") }
            guard uid == 0 else { return .fail("Run this with sudo.") }
            return startLearn(modeId: r.mode ?? "")
        case "learn_stop":
            guard BuildInfo.isDevBuild else { return .fail("learn is only available in dev builds.") }
            guard uid == 0 else { return .fail("Run this with sudo.") }
            return stopLearn(apply: r.apply ?? false)
        case "update_propose":
            guard let p = r.path else { return .fail("missing path") }
            do {
                let msg = try updater.propose(path: p)
                restartSoon()
                return .success(msg)
            } catch { return .fail("\(error)") }
        case "update_rollback":
            do {
                let msg = try updater.rollback()
                restartSoon()
                return .success(msg)
            } catch { return .fail("\(error)") }
        case "update_list":
            return IPCResponse(ok: true, lines: updater.list())
        case "emergency_off":
            return emergencyOff(r, uid: uid)
        default:
            return .fail("unknown command '\(r.cmd)'")
        }
    }

    private func availability(_ m: ModeConfig) -> (Bool, String?) {
        let used = pstate.used(m.id)
        if let limit = m.dailyLimit, used >= limit {
            return (false, limit == 0 ? "Disabled" : "Used \(used) of \(limit) today")
        }
        if let limit = m.weeklyLimit {
            let week = pstate.usedThisWeek(m.id)
            if week >= limit { return (false, "Used \(week) of \(limit) this week — resets Monday") }
        }
        return (true, nil)
    }

    private func status(uid: uid_t) -> DaemonStatus {
        let modes = config.modes.map { m -> ModeStatus in
            let (ok, why) = availability(m)
            var ms = ModeStatus(id: m.id, name: m.name, description: m.description, minutes: m.minutes,
                                dailyLimit: m.dailyLimit, usedToday: pstate.used(m.id), available: ok, unavailableReason: why)
            ms.weeklyLimit = m.weeklyLimit
            ms.usedThisWeek = pstate.usedThisWeek(m.id)
            ms.openWeb = m.isOpenWeb
            ms.intentMinWords = config.intentMinWords(for: m)
            ms.startDelaySeconds = m.startDelaySeconds ?? 0
            return ms
        }
        let exempt = userName(uid).map { config.exemptUsers.contains($0) } ?? false
        var st = DaemonStatus(state: "locked", version: BuildInfo.version, devBuild: BuildInfo.isDevBuild, modes: modes,
                              intentMinWords: config.intentMinWords, extensionMinReasonWords: config.extensionMinReasonWords,
                              extensionMinutes: config.extensionMinutes, exempt: exempt, notice: notice)
        st.testEndsAt = testEndsAt?.timeIntervalSince1970
        if case .locked = phase, let p = pendingStart {
            st.pendingModeId = p.modeId
            st.pendingModeName = config.mode(p.modeId)?.name ?? p.modeId
            st.pendingIntent = p.intent
            st.pendingReadyIn = max(0, Int((p.readyAt - ProcessInfo.processInfo.systemUptime).rounded(.up)))
        }
        switch phase {
        case .locked:
            break
        case .session:
            guard let s = pstate.session else { break }
            let mode = config.mode(s.modeId)
            let remaining = max(0, Int(s.endsAt.timeIntervalSinceNow.rounded()))
            st.state = "session"
            st.modeId = s.modeId
            st.modeName = mode?.name ?? s.modeId
            st.intent = s.intent
            st.endsAt = s.endsAt.timeIntervalSince1970
            st.remainingSeconds = remaining
            st.warning = remaining <= config.warningSeconds
            st.extended = s.extended
            if mode?.allowExtension == false || config.extensionMinutes == 0 {
                st.extensionState = "unavailable"
            } else if s.extended {
                st.extensionState = "used"
            } else if let at = extensionRequestedAt {
                let left = Double(config.extensionWaitSeconds) - (ProcessInfo.processInfo.systemUptime - at)
                st.extensionState = left > 0 ? "waiting" : "ready"
                st.extensionReadyIn = left > 0 ? Int(left.rounded(.up)) : 0
            } else {
                st.extensionState = "available"
            }
        case .learn(let id, let until):
            st.state = "learn"
            st.modeId = id
            st.modeName = "Learn: " + (config.mode(id)?.name ?? id)
            st.endsAt = until.timeIntervalSince1970
            st.remainingSeconds = max(0, Int(until.timeIntervalSinceNow))
        }
        return st
    }

    private func start(modeId: String, intent: String, uid: uid_t) -> IPCResponse {
        guard case .locked = phase else { return .fail("A session is already running.") }
        guard let mode = config.mode(modeId) else { return .fail("Unknown mode '\(modeId)'.") }
        let text = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = TextUtil.wordCount(text)
        let minWords = config.intentMinWords(for: mode)
        guard words >= minWords else {
            return .fail("Describe what you're here for in at least \(minWords) words (you have \(words)).")
        }
        let (ok, why) = availability(mode)
        guard ok else { return .fail("\(mode.name) is not available: \(why ?? "")") }

        if let delay = mode.startDelaySeconds, delay > 0 {
            pendingStart = PendingStart(modeId: mode.id, intent: text,
                                        readyAt: ProcessInfo.processInfo.systemUptime + Double(delay), uid: uid)
            Log.info("start of \(mode.id) requested; pausing \(delay) s")
            var r = IPCResponse(ok: true, message: "\(mode.name) opens in \(delay) seconds.")
            r.waitSeconds = delay
            return r
        }
        return beginSession(mode: mode, intent: text, uid: uid)
    }

    /// Second step of a delayed start, after the pause.
    private func confirmStart(uid: uid_t) -> IPCResponse {
        guard case .locked = phase else { return .fail("A session is already running.") }
        guard let p = pendingStart else { return .fail("Nothing is waiting to start.") }
        let left = p.readyAt - ProcessInfo.processInfo.systemUptime
        guard left <= 0 else { return .fail("Wait \(Int(left.rounded(.up))) more seconds.") }
        pendingStart = nil
        guard let mode = config.mode(p.modeId) else { return .fail("Unknown mode '\(p.modeId)'.") }
        let (ok, why) = availability(mode)
        guard ok else { return .fail("\(mode.name) is not available: \(why ?? "")") }
        return beginSession(mode: mode, intent: p.intent, uid: uid)
    }

    private func beginSession(mode: ModeConfig, intent text: String, uid: uid_t) -> IPCResponse {
        pendingStart = nil
        let now = Date()
        pstate.session = SessionRecord(modeId: mode.id, intent: text, startedAt: now,
                                       endsAt: now.addingTimeInterval(Double(mode.minutes) * 60), extended: false)
        pstate.increment(mode.id)
        pstate.save()
        phase = .session
        extensionRequestedAt = nil
        applyPolicy(reason: "session started")
        SessionLog.write(["event": "session_start", "mode": mode.id, "intent": text, "minutes": mode.minutes, "uid": Int(uid)])
        let launch = mode.launch ?? mode.apps.prefix(1).map { LaunchItem(bundleId: $0.bundleId) }
        return IPCResponse(ok: true, message: "\(mode.name) for \(mode.minutes) minutes.", launch: launch)
    }

    private func endSession(early: Bool, reason: String) {
        guard case .session = phase, let s = pstate.session else { return }
        SessionLog.write(["event": "session_end", "mode": s.modeId, "intent": s.intent,
                          "started": ISO8601DateFormatter().string(from: s.startedAt),
                          "extended": s.extended, "extension_reason": s.extensionReason ?? "",
                          "ended_early": early, "reason": reason])
        pstate.session = nil
        pstate.save()
        phase = .locked
        extensionRequestedAt = nil
        applyPolicy(reason: "session ended: \(reason)")
    }

    private func extendRequest() -> IPCResponse {
        guard case .session = phase, let s = pstate.session else { return .fail("No session is running.") }
        guard !s.extended else { return .fail("This session was already extended.") }
        guard config.mode(s.modeId)?.allowExtension != false, config.extensionMinutes > 0 else {
            return .fail("This mode can't be extended.")
        }
        if extensionRequestedAt == nil { extensionRequestedAt = ProcessInfo.processInfo.systemUptime }
        return .success("Wait \(config.extensionWaitSeconds) seconds, then type your reason.")
    }

    private func extendConfirm(reason: String) -> IPCResponse {
        guard case .session = phase, var s = pstate.session else { return .fail("No session is running.") }
        guard !s.extended else { return .fail("This session was already extended.") }
        guard let at = extensionRequestedAt else { return .fail("Request the extension first.") }
        guard ProcessInfo.processInfo.systemUptime - at >= Double(config.extensionWaitSeconds) else {
            return .fail("The waiting time isn't over yet.")
        }
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TextUtil.wordCount(text) >= config.extensionMinReasonWords else {
            return .fail("Give a reason of at least \(config.extensionMinReasonWords) words.")
        }
        s.endsAt = s.endsAt.addingTimeInterval(Double(config.extensionMinutes) * 60)
        s.extended = true
        s.extensionReason = text
        pstate.session = s
        pstate.save()
        extensionRequestedAt = nil
        SessionLog.write(["event": "session_extended", "mode": s.modeId, "reason": text])
        Log.info("session extended by \(config.extensionMinutes) min")
        return .success("+\(config.extensionMinutes) minutes.")
    }

    // MARK: learn (dev builds)

    private func startLearn(modeId: String) -> IPCResponse {
        guard case .locked = phase else { return .fail("End the running session first.") }
        guard let mode = config.mode(modeId) else { return .fail("Unknown mode '\(modeId)'.") }
        _ = box.takeLearned()
        phase = .learn(modeId: mode.id, until: Date().addingTimeInterval(Double(config.learnMaxMinutes) * 60))
        applyPolicy(reason: "learn started")
        return .success("""
            Learn mode for '\(mode.name)' is on for up to \(config.learnMaxMinutes) minutes.
            Every website is reachable now (except the adult filter). Use the mode's apps the way you normally would,
            then run:  sudo intentmode learn stop          (shows the new domains)
                  or:  sudo intentmode learn stop --apply  (also adds them to the mode in config.json)
            """)
    }

    private func stopLearn(apply: Bool) -> IPCResponse {
        guard case .learn(let id, _) = phase else { return .fail("Learn mode is not running.") }
        let names = box.takeLearned()
        var lines: [String] = []
        if let mode = config.mode(id) {
            let known = DomainMatcher(entries: config.domains(for: mode))
            lines = names.filter { $0.contains(".") && !known.matches($0) && !blocklist.matches($0) && !$0.hasSuffix(".arpa") }.sorted()
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let file = Paths.learned + "/\(id)-\(stamp).txt"
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: file))
            if apply && !lines.isEmpty {
                do {
                    try ConfigEditor.addDomains(lines, toMode: id, path: Paths.config)
                } catch {
                    phase = .locked
                    applyPolicy(reason: "learn stopped")
                    return IPCResponse(ok: false, error: "Could not update config.json: \(error)", lines: lines)
                }
            }
        }
        phase = .locked
        applyPolicy(reason: "learn stopped")
        if apply { reloadConfigIfChanged(force: true) }
        let msg = lines.isEmpty ? "No new domains were seen." :
            (apply ? "Added \(lines.count) domains to '\(id)' in config.json:" : "\(lines.count) new domains (not added; use --apply to add them):")
        return IPCResponse(ok: true, message: msg, lines: lines)
    }

    // MARK: emergency off & restart

    /// Test mode: uninstall everything (logs are kept in /Users/Shared/IntentMode/last-test-logs).
    private func stopTest() -> IPCResponse {
        testStopping = true
        SessionLog.write(["event": "test_stopped"])
        guard spawnDetached("/bin/bash", [Paths.uninstallScript, "--yes", "--delay"]) else {
            testStopping = false
            return .fail("Could not start the uninstaller. Restart your Mac: test mode always switches off on restart.")
        }
        return .success("Turning Intent Mode off. This takes a few seconds.")
    }

    private func emergencyOff(_ r: IPCRequest, uid: uid_t) -> IPCResponse {
        if testEndsAt != nil {
            Log.warn("test stopped from the intent screen (uid \(uid))")
            return stopTest()
        }
        guard BuildInfo.isDevBuild else { return .fail("emergency-off is only available in dev builds.") }
        if uid != 0 {
            guard let u = r.username, let p = r.password, Self.verifyAdmin(user: u, password: p) else {
                Log.warn("emergency-off: wrong admin credentials (uid \(uid))")
                return .fail("That is not a valid admin name and password.")
            }
        }
        Log.warn("EMERGENCY OFF requested (uid \(uid))")
        SessionLog.write(["event": "emergency_off", "uid": Int(uid)])
        guard spawnDetached("/bin/bash", [Paths.emergencyScript, "--delay"]) else {
            return .fail("Could not start \(Paths.emergencyScript). Run it with sudo from a Terminal.")
        }
        return .success("Emergency off is running. Enforcement stops in a few seconds.")
    }

    static func verifyAdmin(user: String, password: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let rec = try node.record(withRecordType: kODRecordTypeUsers, name: user, attributes: nil)
            try rec.verifyPassword(password)
        } catch {
            return false
        }
        return run("/usr/sbin/dseditgroup", ["-o", "checkmember", "-m", user, "admin"]).ok
    }

    /// After an update or rollback: restart the intent screen, then exit so intentguard starts the new `current`.
    private func restartSoon() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if let uid = consoleUID() {
                run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(Paths.agentLabel)"])
            }
            Log.info("exiting for restart")
            exit(0)
        }
    }
}
