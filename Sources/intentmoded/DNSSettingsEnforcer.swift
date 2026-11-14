import Foundation
import SystemConfiguration
import IntentCore

/// Keeps every network service's DNS set to our resolver (127.0.0.1, ::1).
///
/// This is for convenience, not security: pf only lets DNS reach the upstream filter servers,
/// so if DNS is changed anyway, names simply stop resolving (fail closed).
/// The original settings are saved once to dns-backup.txt so emergency-off/uninstall can restore them.
final class DNSSettingsEnforcer {
    private let q = DispatchQueue(label: "intentmode.dnssettings")
    private let ours = ["127.0.0.1", "::1"]
    private let ns = "/usr/sbin/networksetup"
    private var timer: DispatchSourceTimer?
    private var lastFull = Date.distantPast

    func start() {
        q.async { self.enforceAll() }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        timer = t
    }

    private func check() {
        // Cheap check every 5 s; full pass every 60 s to catch newly added services.
        if Date().timeIntervalSince(lastFull) > 60 || !globalDNSIsOurs() { enforceAll() }
    }

    private func globalDNSIsOurs() -> Bool {
        guard let store = SCDynamicStoreCreate(nil, "intentmoded" as CFString, nil, nil) else { return true }
        guard let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = dict["ServerAddresses"] as? [String] else {
            return true // no DNS at all (offline): nothing to fix
        }
        return Set(servers).isSubset(of: Set(ours))
    }

    private func services() -> [String] {
        let r = run(ns, ["-listallnetworkservices"])
        guard r.ok else { return [] }
        return r.out.split(separator: "\n").dropFirst().map { line in
            var s = String(line)
            if s.hasPrefix("*") { s.removeFirst() } // disabled service
            return s
        }.filter { !$0.isEmpty }
    }

    private func currentServers(_ svc: String) -> [String]? {
        let r = run(ns, ["-getdnsservers", svc])
        guard r.ok, !r.out.contains("Error") else { return nil }
        if r.out.contains("There aren't any DNS Servers") { return [] }
        return r.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func enforceAll() {
        lastFull = Date()
        var backup = Self.loadBackup()
        var backupChanged = false
        for svc in services() {
            guard let cur = currentServers(svc) else { continue }
            if cur == ours { continue }
            if backup[svc] == nil {
                backup[svc] = cur.isEmpty ? "Empty" : cur.joined(separator: " ")
                backupChanged = true
            }
            let r = run(ns, ["-setdnsservers", svc] + ours)
            if r.ok {
                Log.info("DNS for '\(svc)' set to 127.0.0.1 (was: \(cur.isEmpty ? "automatic" : cur.joined(separator: " ")))")
            } else {
                Log.error("could not set DNS for '\(svc)': \(r.err)")
            }
        }
        if backupChanged { Self.saveBackup(backup) }
    }

    // Format: one line per service, "<service name>\t<servers or Empty>" — easy to read from bash.
    static func loadBackup() -> [String: String] {
        guard let text = try? String(contentsOfFile: Paths.dnsBackup, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2 { out[String(parts[0])] = String(parts[1]) }
        }
        return out
    }

    static func saveBackup(_ b: [String: String]) {
        let text = b.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n") + "\n"
        try? FileUtil.writeAtomically(Data(text.utf8), to: Paths.dnsBackup, mode: 0o644)
    }
}
