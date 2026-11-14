import Foundation
import IntentCore

/// Weekly refresh of the adult blocklists (blocklist_sources in config.json).
///
/// Runs during sessions, when the list servers may be reachable (raw.githubusercontent.com is
/// allowed in Claude mode, everything in Research). Downloads are merged into the local files and
/// entries are only ever ADDED, never removed, so a broken or tampered download can't open anything.
final class BlocklistRefresher {
    private let q = DispatchQueue(label: "intentmode.blocklist-refresh")
    private var running = false
    private var lastAttempt = Date.distantPast
    private var stampPath: String { Paths.base + "/blocklists/last-refresh" }

    /// Called from the daemon tick. Cheap when nothing is due.
    func maybeRefresh(sources: [BlocklistSource], inSession: Bool, onUpdated: @escaping () -> Void) {
        guard inSession, !sources.isEmpty, !running else { return }
        guard Date().timeIntervalSince(lastAttempt) > 30 * 60 else { return }   // retry at most every 30 min
        let last = (try? String(contentsOfFile: stampPath, encoding: .utf8)).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        guard Date().timeIntervalSince1970 - last > 7 * 86400 else { return }
        running = true
        lastAttempt = Date()
        q.async {
            var anyAdded = false, anyOK = false
            for s in sources {
                switch self.refresh(s) {
                case .some(let added): anyOK = true; if added > 0 { anyAdded = true }
                case .none: break
                }
            }
            if anyOK {
                try? FileUtil.writeAtomically(Data(String(Date().timeIntervalSince1970).utf8), to: self.stampPath, mode: 0o644)
            }
            DispatchQueue.main.async { self.running = false }
            if anyAdded { onUpdated() }
        }
    }

    /// Returns the number of new entries, or nil if the download failed.
    private func refresh(_ s: BlocklistSource) -> Int? {
        guard let url = URL(string: s.url) else { return nil }
        var data: Data?
        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue("IntentMode-blocklist-refresh", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { d, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 { data = d }
            sem.signal()
        }.resume()
        sem.wait()
        guard let data, let text = String(data: data, encoding: .utf8) else {
            Log.info("blocklist refresh: \(s.url) not reachable right now")
            return nil
        }
        let fresh = DomainMatcher.entries(fromListFile: text)
        guard fresh.count > 1000 else {
            Log.warn("blocklist refresh: \(s.url) returned only \(fresh.count) entries; ignored")
            return nil
        }
        let path = s.file.hasPrefix("/") ? s.file : Paths.base + "/" + s.file
        let existingText = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var all = Set(DomainMatcher.entries(fromListFile: existingText).map { $0.lowercased() })
        let before = all.count
        for e in fresh { all.insert(e.lowercased()) }
        let added = all.count - before
        guard added > 0 else { return 0 }
        let header = "# Intent Mode blocklist (merged, add-only). Source: \(s.url)\n"
        let out = header + all.sorted().joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileUtil.writeAtomically(Data(out.utf8), to: path, mode: 0o644)
            Log.info("blocklist refresh: +\(added) entries for \(s.file) (now \(all.count))")
        } catch {
            Log.error("blocklist refresh: could not write \(path): \(error)")
            return nil
        }
        return added
    }
}
