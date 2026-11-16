import Foundation
import Darwin
import IntentCore

/// Time that ignores changes to the Mac's clock, for session ends and lock-down delays.
///
/// - While the daemon runs, the wall clock is compared every second with a monotonic clock that keeps counting
///   during sleep (CLOCK_MONOTONIC_RAW). If the wall clock jumps (someone changed the date), the jump is
///   cancelled out by an offset.
/// - Every 10 minutes the offset is corrected against network time (SNTP to time.apple.com, port 123 is allowed by pf).
/// - The offset is saved, so it survives restarts.
final class TrustedClock {
    private let lock = NSLock()
    private var offset: TimeInterval
    private var lastWall: TimeInterval
    private var lastMono: TimeInterval
    private var path: String { Paths.base + "/clock-offset.txt" }

    init() {
        offset = (try? String(contentsOfFile: Paths.base + "/clock-offset.txt", encoding: .utf8))
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        lastWall = Date().timeIntervalSince1970
        lastMono = TrustedClock.mono()
    }

    static func mono() -> TimeInterval { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000 }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return Date().addingTimeInterval(offset)
    }

    /// Called every second: cancels out jumps of the wall clock. Returns true if a jump was detected.
    @discardableResult
    func tick() -> Bool {
        let wall = Date().timeIntervalSince1970, m = TrustedClock.mono()
        lock.lock()
        let drift = (wall - lastWall) - (m - lastMono)
        lastWall = wall; lastMono = m
        var changed = false
        if abs(drift) > 5 {
            offset -= drift
            changed = true
        }
        let o = offset
        lock.unlock()
        if changed {
            Log.warn("the system clock was changed by \(Int(drift)) s — Intent Mode keeps counting real time")
            save(o)
        }
        return changed
    }

    /// Corrects the offset against network time (call off the main queues).
    func syncWithNetwork(upstream: [String]) {
        guard let net = Self.networkTime(upstream: upstream) else { return }
        lock.lock()
        let newOffset = net.timeIntervalSince1970 - Date().timeIntervalSince1970
        let old = offset
        offset = abs(newOffset) < 2 ? 0 : newOffset
        let o = offset
        lock.unlock()
        if abs(o - old) > 5 { Log.info("clock offset from network time: \(Int(o)) s") }
        save(o)
    }

    private func save(_ o: TimeInterval) {
        try? FileUtil.writeAtomically(Data(String(o).utf8), to: path, mode: 0o644)
    }

    /// SNTP: resolves time.apple.com through the upstream DNS directly (not the mode allowlist) and asks for the time.
    static func networkTime(upstream: [String]) -> Date? {
        let q = DNSMessage.makeQuery(id: UInt16.random(in: 1...0xFFFE), name: "time.apple.com", qtype: DNSMessage.typeA)
        guard let r = Upstream.query(q, servers: upstream, timeout: 2),
              let ip = DNSMessage.addresses(in: r).first(where: { !$0.ip.contains(":") })?.ip else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        Sock.setTimeout(fd, 3)
        let ok = Sock.withAddress(ip, port: 123) { connect(fd, $0, $1) } ?? -1
        guard ok == 0 else { return nil }
        var pkt = [UInt8](repeating: 0, count: 48)
        pkt[0] = 0x1B   // SNTP v3, client
        guard send(fd, pkt, 48, 0) == 48 else { return nil }
        var buf = [UInt8](repeating: 0, count: 48)
        guard recv(fd, &buf, 48, 0) >= 48 else { return nil }
        let secs = UInt32(buf[40]) << 24 | UInt32(buf[41]) << 16 | UInt32(buf[42]) << 8 | UInt32(buf[43])
        let frac = UInt32(buf[44]) << 24 | UInt32(buf[45]) << 16 | UInt32(buf[46]) << 8 | UInt32(buf[47])
        guard secs > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(secs) - 2_208_988_800 + Double(frac) / 4_294_967_296)
    }
}
