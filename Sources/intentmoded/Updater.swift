import Foundation
import IntentCore

/// Self-update and rollback.
///
/// propose: copy the build into a root-owned staging folder → verify signature + hashes →
///          version must be newer → run its self-test → move to versions/<v> → point `current`
///          at it → restart. intentguard then watches the new daemon: if it doesn't report
///          healthy within 2 minutes, it switches back automatically.
/// rollback: point `current` at the most recent known-good older version and restart (instant).
///
/// Phases 1–3 apply immediately. Phase 4 adds the 24-hour delay for new code.
final class Updater {
    struct UpdateError: Error, CustomStringConvertible { let description: String }

    func propose(path rawPath: String) throws -> String {
        let fm = FileManager.default
        let src = (rawPath as NSString).expandingTildeInPath
        guard fm.fileExists(atPath: src) else { throw UpdateError(description: "not found: \(src)") }
        guard let pub = try? PackageTool.loadKey(Paths.updatePublicKey) else {
            throw UpdateError(description: "no update public key at \(Paths.updatePublicKey)")
        }

        // 1. Copy into a root-owned staging folder first, so the files can't change while we check them.
        let stage = Paths.staging + "/" + UUID().uuidString
        try fm.createDirectory(atPath: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(atPath: stage) }
        let pkg: String
        if src.hasSuffix(".tar.gz") || src.hasSuffix(".tgz") {
            let r = run("/usr/bin/tar", ["-xzf", src, "-C", stage], timeout: 120)
            guard r.ok else { throw UpdateError(description: "could not unpack: \(r.err)") }
            let tops = (try fm.contentsOfDirectory(atPath: stage)).filter { !$0.hasPrefix(".") }
            guard tops.count == 1 else { throw UpdateError(description: "archive must contain exactly one folder") }
            pkg = stage + "/" + tops[0]
        } else {
            pkg = stage + "/pkg"
            let r = run("/usr/bin/ditto", [src, pkg], timeout: 120)
            guard r.ok else { throw UpdateError(description: "could not copy: \(r.err)") }
        }
        run("/usr/sbin/chown", ["-R", "root:wheel", stage])
        run("/bin/chmod", ["-R", "go-w", stage])

        // 2. Verify.
        let manifest: PackageManifest
        do { manifest = try PackageTool.verify(root: pkg, publicKey: pub) } catch {
            throw UpdateError(description: "\(error)")
        }
        let v = manifest.version
        guard VersionCompare.isNewer(v, than: BuildInfo.version) else {
            throw UpdateError(description: "version \(v) is not newer than the installed \(BuildInfo.version). Bump the VERSION file and rebuild. (To go back to an older version, use rollback.)")
        }

        // 3. Self-test the new daemon against the existing config.
        let test = run(pkg + "/bin/intentmoded", ["--self-test", "--config", Paths.config], timeout: 60)
        guard test.ok else {
            throw UpdateError(description: "new version failed its self-test:\n\(test.out)\(test.err)")
        }

        // 4. Install side by side and switch.
        let dest = Paths.versions + "/" + v
        if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
        try fm.moveItem(atPath: pkg, toPath: dest)
        var st = UpdateState.load() ?? UpdateState(current: BuildInfo.version, knownGood: [BuildInfo.version])
        st.previous = BuildInfo.version
        st.current = v
        st.pending = v
        st.pendingSince = Date().timeIntervalSince1970
        try st.save()
        try UpdateState.pointCurrent(to: v)
        Log.info("update \(BuildInfo.version) → \(v) applied; restarting. Changelog: \(manifest.changelog)")
        SessionLog.write(["event": "update_applied", "from": BuildInfo.version, "to": v])
        return "Installed \(v). The daemon and intent screen restart now. If \(v) fails to start within 2 minutes, \(BuildInfo.version) comes back automatically.\nChangelog: \(manifest.changelog)"
    }

    func rollback() throws -> String {
        guard var st = UpdateState.load() else { throw UpdateError(description: "no update state found") }
        let fm = FileManager.default
        guard let target = st.knownGood.reversed().first(where: {
            $0 != BuildInfo.version && fm.fileExists(atPath: Paths.versions + "/" + $0 + "/bin/intentmoded")
        }) else {
            throw UpdateError(description: "no earlier known-good version is installed")
        }
        st.knownGood.removeAll { $0 == BuildInfo.version }   // the version we're leaving is no longer trusted
        st.previous = BuildInfo.version
        st.current = target
        st.pending = nil
        try st.save()
        try UpdateState.pointCurrent(to: target)
        Log.warn("rolled back \(BuildInfo.version) → \(target)")
        SessionLog.write(["event": "rollback", "from": BuildInfo.version, "to": target])
        return "Rolled back to \(target). Restarting now."
    }

    func list() -> [String] {
        let st = UpdateState.load()
        let installed = ((try? FileManager.default.contentsOfDirectory(atPath: Paths.versions)) ?? [])
            .filter { VersionCompare.parse($0) != nil }
            .sorted { VersionCompare.isNewer($1, than: $0) }
        return installed.map { v in
            var tags: [String] = []
            if v == BuildInfo.version { tags.append("running") }
            if st?.knownGood.contains(v) == true { tags.append("known-good") }
            if st?.pending == v { tags.append("pending verification") }
            return tags.isEmpty ? v : "\(v)  (\(tags.joined(separator: ", ")))"
        }
    }

    /// Keeps the running version, any pending one, and the 3 most recent known-good versions.
    func prune() {
        guard let st = UpdateState.load() else { return }
        var keep = Set(st.knownGood.suffix(3))
        keep.insert(BuildInfo.version)
        keep.insert(st.current)
        if let p = st.pending { keep.insert(p) }
        if let p = st.previous { keep.insert(p) }
        let fm = FileManager.default
        for v in (try? fm.contentsOfDirectory(atPath: Paths.versions)) ?? [] where !keep.contains(v) {
            Log.info("removing old version \(v)")
            try? fm.removeItem(atPath: Paths.versions + "/" + v)
        }
    }
}
