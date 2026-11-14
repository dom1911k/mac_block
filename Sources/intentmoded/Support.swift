import Foundation
import Darwin
import IntentCore

// MARK: - Logging

enum Log {
    private static let q = DispatchQueue(label: "intentmode.log")
    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static var path = Paths.log
    static let toStderr = isatty(2) != 0

    static func info(_ m: String) { write("INFO", m) }
    static func warn(_ m: String) { write("WARN", m) }
    static func error(_ m: String) { write("ERROR", m) }

    private static func write(_ level: String, _ msg: String) {
        let line = "\(fmt.string(from: Date())) [\(level)] \(msg)\n"
        if toStderr { FileHandle.standardError.write(Data(line.utf8)) }
        q.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 5_000_000 {
                try? fm.removeItem(atPath: path + ".1")
                try? fm.moveItem(atPath: path, toPath: path + ".1")
            }
            if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644]) }
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            }
        }
    }
}

// MARK: - Running commands

struct ShellResult {
    let status: Int32
    let out: String
    let err: String
    var ok: Bool { status == 0 }
}

/// Runs a program (no shell involved) and collects its output.
@discardableResult
func run(_ path: String, _ args: [String], input: String? = nil, timeout: TimeInterval = 30) -> ShellResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    let inPipe = input != nil ? Pipe() : nil
    p.standardInput = inPipe ?? FileHandle.nullDevice
    do { try p.run() } catch {
        return ShellResult(status: -1, out: "", err: "could not start \(path): \(error)")
    }
    if let inPipe, let input {
        inPipe.fileHandleForWriting.write(Data(input.utf8))
        try? inPipe.fileHandleForWriting.close()
    }
    var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    p.waitUntilExit()
    killer.cancel()
    return ShellResult(status: p.terminationStatus,
                       out: String(decoding: outData, as: UTF8.self),
                       err: String(decoding: errData, as: UTF8.self))
}

/// Starts a program in its own session so it survives the daemon being stopped (used by emergency-off).
func spawnDetached(_ path: String, _ args: [String]) -> Bool {
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    let r = posix_spawn(&pid, path, nil, &attr, argv, environ)
    return r == 0
}

/// Clears macOS's DNS cache so old answers (or old NXDOMAINs) don't linger after a policy change.
func flushDNSCache() {
    run("/usr/bin/dscacheutil", ["-flushcache"])
    run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
}

func consoleUID() -> uid_t? {
    var st = stat()
    guard stat("/dev/console", &st) == 0, st.st_uid != 0 else { return nil }
    return st.st_uid
}

func userName(_ uid: uid_t) -> String? {
    guard let pw = getpwuid(uid) else { return nil }
    return String(cString: pw.pointee.pw_name)
}

/// Makes sure the intent screen agent is loaded and running for a GUI user.
func ensureScreenAgent(uid: uid_t) {
    let domain = "gui/\(uid)"
    run("/bin/launchctl", ["enable", "\(domain)/\(Paths.agentLabel)"])
    run("/bin/launchctl", ["bootstrap", domain, Paths.agentPlistInUse])   // fails harmlessly if already loaded
    run("/bin/launchctl", ["kickstart", "\(domain)/\(Paths.agentLabel)"])
}

// MARK: - Persistent state

struct SessionRecord: Codable {
    var modeId: String
    var intent: String
    var startedAt: Date
    var endsAt: Date
    var extended: Bool
    var extensionReason: String?
}

/// Survives daemon restarts and updates: today's usage and the running session.
struct PersistentState: Codable {
    var dailyCounts: [String: [String: Int]] = [:]
    var session: SessionRecord?

    static func load() -> PersistentState {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: Paths.state)),
              let s = try? JSONDecoder().decode(PersistentState.self, from: d) else { return PersistentState() }
        return s
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try FileUtil.writeAtomically(try enc.encode(self), to: Paths.state, mode: 0o600) } catch {
            Log.error("could not save state: \(error)")
        }
    }

    static func dayKey(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    func used(_ mode: String, on day: String = PersistentState.dayKey()) -> Int { dailyCounts[day]?[mode] ?? 0 }

    mutating func increment(_ mode: String) {
        let day = PersistentState.dayKey()
        dailyCounts[day, default: [:]][mode, default: 0] += 1
        let cutoff = PersistentState.dayKey(Date().addingTimeInterval(-21 * 86400))
        dailyCounts = dailyCounts.filter { $0.key >= cutoff }
    }
}

/// Append-only JSON-lines record of sessions. Phase 3 imports it into SQLite.
enum SessionLog {
    static func write(_ event: [String: Any]) {
        var e = event
        e["at"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys]) else { return }
        let path = Paths.sessionLog
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data + Data("\n".utf8))
            try? h.close()
        }
    }
}
