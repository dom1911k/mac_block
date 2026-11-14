import Foundation
import Darwin
import IntentCore

// intentguard — what launchd actually runs (as root). It starts `current/bin/intentmoded`,
// restarts it if it exits, and protects updates:
//
// If a freshly applied version (update-state.json "pending") doesn't write its health file
// within 2 minutes, or exits before doing so, intentguard switches `current` back to the
// previous version and starts that instead. Enforcement stays in place the whole time
// (pf rules and DNS don't depend on the daemon process being alive).
//
// This file is deliberately small and is not replaced by updates (only by install.sh).

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

func glog(_ m: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(m)\n"
    let path = Paths.guardLog
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644])
    }
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
        try? h.close()
    }
}

var childPid: pid_t = 0
let healthTimeout: TimeInterval = 120

// Forward SIGTERM (launchctl bootout / shutdown) to the daemon, then exit.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue.global())
termSource.setEventHandler {
    if childPid > 0 {
        kill(childPid, SIGTERM)
        var st: Int32 = 0
        waitpid(childPid, &st, 0)
    }
    exit(0)
}
termSource.resume()

func spawnDaemon(_ path: String) -> pid_t? {
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup("--guarded"), nil]
    defer { argv.forEach { free($0) } }
    let r = posix_spawn(&pid, path, nil, nil, argv, environ)
    return r == 0 ? pid : nil
}

func restartScreenAgent() {
    var st = stat()
    guard stat("/dev/console", &st) == 0, st.st_uid != 0 else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["kickstart", "-k", "gui/\(st.st_uid)/\(Paths.agentLabel)"]
    try? p.run()
    p.waitUntilExit()
}

func rollback(_ state: UpdateState, failed: String) {
    let fm = FileManager.default
    var st = state
    let candidates = ([st.previous].compactMap { $0 } + st.knownGood.reversed())
        .filter { $0 != failed && fm.fileExists(atPath: Paths.versions + "/" + $0 + "/bin/intentmoded") }
    guard let target = candidates.first else {
        glog("ROLLBACK IMPOSSIBLE: no other version installed. Keeping \(failed).")
        st.pending = nil
        try? st.save()
        return
    }
    do {
        try UpdateState.pointCurrent(to: target)
        st.knownGood.removeAll { $0 == failed }
        st.current = target
        st.pending = nil
        st.previous = nil
        try st.save()
        glog("ROLLED BACK: \(failed) did not become healthy; now running \(target)")
        restartScreenAgent()
    } catch {
        glog("rollback to \(target) failed: \(error)")
    }
}

glog("intentguard \(BuildInfo.version) starting")

while true {
    let state = UpdateState.load()
    let pending = state?.pending
    let exe = Paths.current + "/bin/intentmoded"
    try? FileManager.default.removeItem(atPath: Paths.health)

    guard let pid = spawnDaemon(exe) else {
        glog("could not start \(exe) (errno \(errno))")
        if let state, let p = pending { rollback(state, failed: p) }
        sleep(5)
        continue
    }
    childPid = pid
    let started = Date()
    var healthy = false
    var status: Int32 = 0

    while true {
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid || r < 0 { break }
        if !healthy, let h = try? String(contentsOfFile: Paths.health, encoding: .utf8),
           !h.isEmpty, pending == nil || h.trimmingCharacters(in: .whitespacesAndNewlines) == pending {
            healthy = true
            if var st = UpdateState.load(), let p = st.pending, p == pending {
                if !st.knownGood.contains(p) { st.knownGood.append(p) }
                st.pending = nil
                try? st.save()
                glog("version \(p) is healthy and now known-good")
            }
        }
        if let p = pending, !healthy, Date().timeIntervalSince(started) > healthTimeout {
            glog("version \(p) not healthy after \(Int(healthTimeout)) s; stopping it")
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
            break
        }
        usleep(500_000)
    }
    childPid = 0
    glog("intentmoded (pid \(pid)) exited with status \(status)")

    if let st = UpdateState.load(), let p = st.pending, !healthy {
        rollback(st, failed: p)
    }
    // Avoid a tight crash loop.
    sleep(Date().timeIntervalSince(started) < 10 ? 5 : 1)
}
