import Foundation

/// Every on-disk location in one place. `INTENTMODE_BASE` overrides the base folder (tests only).
public enum Paths {
    public static let base: String = ProcessInfo.processInfo.environment["INTENTMODE_BASE"]
        ?? "/Library/Application Support/IntentMode"

    public static var config: String { base + "/config.json" }
    public static var configLastGood: String { base + "/config.lastgood.json" }
    public static var state: String { base + "/state.json" }
    public static var updateState: String { base + "/update-state.json" }
    public static var versions: String { base + "/versions" }
    public static var current: String { base + "/current" }
    public static var staging: String { base + "/staging" }
    public static var log: String { base + "/daemon.log" }
    public static var guardLog: String { base + "/guard.log" }
    public static var sessionLog: String { base + "/sessions.jsonl" }
    public static var dnsBackup: String { base + "/dns-backup.txt" }
    public static var pfToken: String { base + "/pf-token.txt" }
    public static var updatePublicKey: String { base + "/update_pubkey.b64" }
    public static var health: String { base + "/health" }
    public static var learned: String { base + "/learned" }
    public static var emergencyScript: String { base + "/emergency-off.sh" }
    public static var guardBinary: String { base + "/intentguard" }
    public static var uninstallScript: String { base + "/uninstall.sh" }
    public static var configUpgradeState: String { base + "/config-upgrades.json" }

    // Test mode: launchd plists live inside the IntentMode folder instead of /Library/Launch*,
    // so nothing starts again after a reboot, and a one-shot cleanup job undoes everything at boot.
    public static var testModeFile: String { base + "/test-mode.json" }
    public static var testLaunchdDir: String { base + "/launchd" }
    public static let testCleanupPlist = "/Library/LaunchDaemons/com.intentmode.testcleanup.plist"

    /// The agent plist actually in use (normal install or test mode).
    public static var agentPlistInUse: String {
        FileManager.default.fileExists(atPath: agentPlist) ? agentPlist : testLaunchdDir + "/com.intentmode.screen.plist"
    }

    public static let socket = "/var/run/intentmode.sock"

    /// Child of Apple's "com.apple/*" anchor, so no edit to /etc/pf.conf is needed.
    /// The "000." prefix makes it sort before Apple's own sub-anchors.
    public static let pfAnchor = "com.apple/000.intentmode"
    public static let pfTable = "im_allow"

    public static let daemonLabel = "com.intentmode.daemon"
    public static let agentLabel = "com.intentmode.screen"
    public static let daemonPlist = "/Library/LaunchDaemons/com.intentmode.daemon.plist"
    public static let agentPlist = "/Library/LaunchAgents/com.intentmode.screen.plist"
    public static let screenBundleID = "com.intentmode.screen"
}

/// Present only during a test install. When `endsAt` passes, everything is uninstalled automatically.
public struct TestMode: Codable {
    public var endsAt: Double

    public static func load() -> TestMode? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: Paths.testModeFile)) else { return nil }
        return try? JSONDecoder().decode(TestMode.self, from: d)
    }
}

public enum FileUtil {
    /// Writes atomically (temp file + rename) and sets POSIX permissions.
    public static func writeAtomically(_ data: Data, to path: String, mode: Int = 0o644) throws {
        let url = URL(fileURLWithPath: path)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    public static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
