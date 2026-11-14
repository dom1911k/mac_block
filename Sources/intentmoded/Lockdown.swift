import Foundation
import IntentCore

/// Phase 4 lock-down state (root-only file). While active:
///  - `sudo` is denied for your account (a sudoers rule, validated with visudo before it's put in place),
///  - emergency-off and learn are refused,
///  - loosening config changes and updates wait `loosening_delay_hours`,
///  - a ONE-TIME escape: "turn off lock-down" takes effect after `disable_delay_hours`. It disappears for good
///    once used, or once you confirm you'll keep using Intent Mode as intended.
struct LockdownState: Codable {
    var enabledAt: Double
    var user: String
    var escapeAvailable: Bool
    var disableRequestedAt: Double?
}

struct PendingChange: Codable {
    var id: String
    var kind: String            // "config" | "update"
    var description: String
    var dueAt: Double           // wall clock (seconds since 1970)
    var file: String?           // config: the proposed config.json copy
    var baseHash: String?       // config: hash of config.json when proposed
    var version: String?        // update
    var changelog: String?
}

enum Lockdown {
    static var statePath: String { Paths.base + "/lockdown.json" }
    static var pendingPath: String { Paths.base + "/pending.json" }
    static var pendingDir: String { Paths.base + "/pending" }
    static let sudoersPath = "/etc/sudoers.d/zz-intentmode-lockdown"
    /// Remembers that the one-time escape was used (kept outside the IntentMode folder too).
    static let escapeUsedMarkers = [Paths.base + "/lockdown-escape-used", "/Library/Preferences/com.intentmode.escape-used"]
    static let keepPhrase = "I will keep using Intent Mode as intended"

    static func load() -> LockdownState? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: statePath)) else { return nil }
        return try? JSONDecoder().decode(LockdownState.self, from: d)
    }

    static func save(_ s: LockdownState?) {
        if let s, let d = try? JSONEncoder().encode(s) {
            try? FileUtil.writeAtomically(d, to: statePath, mode: 0o600)
        } else {
            try? FileManager.default.removeItem(atPath: statePath)
        }
    }

    static func loadPending() -> [PendingChange] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: pendingPath)) else { return [] }
        return (try? JSONDecoder().decode([PendingChange].self, from: d)) ?? []
    }

    static func savePending(_ p: [PendingChange]) {
        if let d = try? JSONEncoder().encode(p) { try? FileUtil.writeAtomically(d, to: pendingPath, mode: 0o600) }
    }

    static var escapeWasUsed: Bool { escapeUsedMarkers.contains { FileManager.default.fileExists(atPath: $0) } }

    static func markEscapeUsed() {
        for m in escapeUsedMarkers { FileManager.default.createFile(atPath: m, contents: Data(), attributes: [.posixPermissions: 0o644]) }
    }

    /// Writes the sudoers rule that denies sudo for `user`. Returns an error message on failure.
    static func installSudoersRule(user: String) -> String? {
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return "invalid user name '\(user)'" }
        let tmp = Paths.base + "/sudoers.tmp"
        let rule = "# Intent Mode lock-down: no sudo for \(user). Removed when lock-down is turned off.\n\(user) ALL=(ALL) !ALL\n"
        do { try FileUtil.writeAtomically(Data(rule.utf8), to: tmp, mode: 0o440) } catch { return "\(error)" }
        let check = run("/usr/sbin/visudo", ["-cf", tmp])
        guard check.ok else {
            try? FileManager.default.removeItem(atPath: tmp)
            return "visudo rejected the rule: \(check.out)\(check.err)"
        }
        run("/usr/sbin/chown", ["root:wheel", tmp])
        guard rename(tmp, sudoersPath) == 0 else { return "could not install \(sudoersPath) (errno \(errno))" }
        return nil
    }

    static func removeSudoersRule() {
        try? FileManager.default.removeItem(atPath: sudoersPath)
    }

    static func sha(_ path: String) -> String? {
        #if canImport(CryptoKit)
        return try? PackageTool.sha256(file: path)
        #else
        return nil
        #endif
    }
}
