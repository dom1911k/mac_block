import AppKit
import Foundation
import IntentCore

/// Simple file log for the screen: ~/Library/Logs/IntentMode-screen.log
enum ScreenLog {
    private static let q = DispatchQueue(label: "intentmode.screen.log")
    private static let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/IntentMode-screen.log")
    private static let fmt = ISO8601DateFormatter()

    static func write(_ m: String) {
        let line = "\(fmt.string(from: Date())) \(m)\n"
        q.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 2_000_000 {
                try? fm.removeItem(atPath: path)
            }
            if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            }
        }
    }
}

/// UI state + talking to the daemon. The screen enforces nothing; it only asks.
final class AppModel: ObservableObject {
    @Published var status: DaemonStatus?
    @Published var daemonReachable = true
    @Published var selectedMode: String?
    @Published var intentText = ""
    @Published var errorText: String?
    @Published var infoText: String?
    @Published var busy = false
    @Published var now = Date()

    // Wi-Fi: temporarily shows the menu bar so the system Wi-Fi menu can be used.
    @Published var wifiUntil: Date?

    // Session panel
    @Published var extensionReason = ""
    @Published var confirmEnd = false

    // Dev-build emergency off
    @Published var showEmergency = false
    @Published var adminUser = NSUserName()
    @Published var adminPassword = ""

    private let ipcQueue = DispatchQueue(label: "intentmode.screen.ipc")
    private var polling = false
    /// Bumped after every command; poll results that started earlier are stale and ignored.
    private var epoch = 0
    private var lastPollError: String?

    var wifiActive: Bool { (wifiUntil ?? .distantPast) > now }

    func poll() {
        guard !polling else { return }
        polling = true
        let started = epoch
        ipcQueue.async {
            let t0 = Date()
            var r: IPCResponse?
            var err: String?
            do { r = try IPCClient.send(IPCRequest(cmd: "status"), timeoutSeconds: 5) } catch { err = "\(error)" }
            let took = Date().timeIntervalSince(t0)
            DispatchQueue.main.async {
                self.polling = false
                if took > 2 { ScreenLog.write("status poll slow: \(String(format: "%.1f", took)) s") }
                guard started == self.epoch else { return } // a command finished meanwhile; this answer is old
                if let s = r?.status {
                    if self.status?.state != s.state { ScreenLog.write("daemon state → \(s.state) \(s.modeId ?? "")") }
                    self.status = s
                    self.daemonReachable = true
                    self.lastPollError = nil
                } else {
                    let e = err ?? r?.error ?? "no status in reply"
                    if e != self.lastPollError { ScreenLog.write("status poll FAILED: \(e)") }
                    self.lastPollError = e
                    self.daemonReachable = false
                }
            }
        }
    }

    func send(_ req: IPCRequest, completion: @escaping (IPCResponse) -> Void) {
        busy = true
        ipcQueue.async {
            let r: IPCResponse
            do { r = try IPCClient.send(req, timeoutSeconds: 30) } catch {
                r = .fail("\(error)")
            }
            ScreenLog.write("\(req.cmd) → \(r.ok ? "ok" : "FAILED: \(r.error ?? "")")\(r.message.map { " (\($0))" } ?? "")")
            DispatchQueue.main.async {
                self.epoch += 1
                self.busy = false
                completion(r)
                self.poll()
            }
        }
    }

    func notifyLaunch(pid: pid_t) {
        ipcQueue.async { _ = try? IPCClient.send(IPCRequest(cmd: "app_launched", pid: pid), timeoutSeconds: 3) }
    }

    // MARK: actions

    func startSession() {
        guard let mode = selectedMode else { return }
        errorText = nil
        send(IPCRequest(cmd: "start", mode: mode, intent: intentText)) { r in
            if r.ok {
                self.intentText = ""
                self.selectedMode = nil
                if r.waitSeconds == nil { self.launch(r.launch ?? []) }
                // Otherwise the daemon pauses first; `checkPendingStart` confirms when the pause is over.
            } else {
                self.errorText = r.error
            }
        }
    }

    private var confirming = false

    /// Called on every status update: confirms a paused start once its countdown reaches 0.
    func checkPendingStart() {
        guard let st = status, st.pendingModeId != nil, (st.pendingReadyIn ?? 1) == 0, !confirming else { return }
        confirming = true
        send(IPCRequest(cmd: "start_confirm")) { r in
            self.confirming = false
            if r.ok { self.launch(r.launch ?? []) } else { self.errorText = r.error }
        }
    }

    func cancelPendingStart() {
        send(IPCRequest(cmd: "start_cancel")) { _ in }
    }

    func endSession() {
        send(IPCRequest(cmd: "end", reason: "ended early from the timer window")) { r in
            self.confirmEnd = false
            if !r.ok { self.errorText = r.error }
        }
    }

    func requestExtension() {
        send(IPCRequest(cmd: "extend_request")) { r in
            if !r.ok { self.errorText = r.error }
        }
    }

    func confirmExtension() {
        send(IPCRequest(cmd: "extend_confirm", reason: extensionReason)) { r in
            if r.ok { self.extensionReason = ""; self.errorText = nil } else { self.errorText = r.error }
        }
    }

    /// Test mode only: no password needed, turns everything off and uninstalls.
    func stopTest() {
        send(IPCRequest(cmd: "emergency_off")) { r in
            if r.ok { self.infoText = r.message } else { self.errorText = r.error }
        }
    }

    func emergencyOff() {
        send(IPCRequest(cmd: "emergency_off", username: adminUser, password: adminPassword)) { r in
            self.adminPassword = ""
            if r.ok { self.infoText = r.message; self.showEmergency = false } else { self.errorText = r.error }
        }
    }

    /// Opens the mode's apps. For Chrome with arguments (e.g. --app=…) when Chrome is already
    /// running, the arguments are passed to the running instance by starting its binary directly.
    func launch(_ items: [LaunchItem]) {
        for item in items {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleId) else {
                errorText = "App not installed: \(item.bundleId)"
                continue
            }
            let args = item.args ?? []
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleId).isEmpty
            if running && !args.isEmpty, let exe = Bundle(url: url)?.executableURL {
                let p = Process()
                p.executableURL = exe
                p.arguments = args
                try? p.run()
            } else {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.arguments = args
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
                    if let err { DispatchQueue.main.async { self.errorText = "Could not open \(item.bundleId): \(err.localizedDescription)" } }
                }
            }
        }
    }
}

func formatRemaining(_ seconds: Int) -> String {
    let s = max(0, seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
