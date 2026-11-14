import Foundation
import Darwin
import IntentCore

// MARK: - Socket helpers

enum Sock {
    /// Calls `body` with a sockaddr for ip:port (IPv4 or IPv6).
    static func withAddress<T>(_ ip: String, port: UInt16, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        if ip.contains(":") {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, ip, &a.sin6_addr) == 1 else { return nil }
            return withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            guard inet_pton(AF_INET, ip, &a.sin_addr) == 1 else { return nil }
            return withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
    }

    static func setTimeout(_ fd: Int32, _ seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
    }

    static func setNoSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setBlocking(_ fd: Int32, _ blocking: Bool) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, blocking ? (flags & ~O_NONBLOCK) : (flags | O_NONBLOCK))
    }

    static func readExact(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            got += n
        }
        return buf
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + off, bytes.count - off) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}

// MARK: - Upstream forwarding

/// Sends queries to the filtering upstream servers (Cloudflare 1.1.1.3 / 1.0.0.3 by default).
enum Upstream {
    static func query(_ q: [UInt8], servers: [String], timeout: Double = 2.5) -> [UInt8]? {
        for s in servers {
            if let r = udp(q, server: s, timeout: timeout) {
                if DNSMessage.isTruncated(r), let t = tcp(q, server: s, timeout: timeout) { return t }
                return r
            }
        }
        return nil
    }

    static func udp(_ q: [UInt8], server: String, timeout: Double) -> [UInt8]? {
        let fd = socket(server.contains(":") ? AF_INET6 : AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        Sock.setTimeout(fd, timeout)
        let connected = Sock.withAddress(server, port: 53) { connect(fd, $0, $1) } ?? -1
        guard connected == 0, send(fd, q, q.count, 0) == q.count else { return nil }
        var buf = [UInt8](repeating: 0, count: 65535)
        for _ in 0..<4 {
            let n = recv(fd, &buf, buf.count, 0)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return nil }
            let r = Array(buf[0..<n])
            if DNSMessage.isResponse(r), DNSMessage.id(r) == DNSMessage.id(q) { return r }
        }
        return nil
    }

    static func tcp(_ q: [UInt8], server: String, timeout: Double) -> [UInt8]? {
        let fd = socket(server.contains(":") ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        Sock.setTimeout(fd, timeout)
        Sock.setNoSigPipe(fd)
        let connected = Sock.withAddress(server, port: 53) { connect(fd, $0, $1) } ?? -1
        guard connected == 0 else { return nil }
        guard Sock.writeAll(fd, [UInt8(q.count >> 8), UInt8(q.count & 0xFF)] + q),
              let lenBytes = Sock.readExact(fd, 2) else { return nil }
        let len = Int(lenBytes[0]) << 8 | Int(lenBytes[1])
        guard len > 0, let r = Sock.readExact(fd, len), DNSMessage.id(r) == DNSMessage.id(q) else { return nil }
        return r
    }
}

// MARK: - Local resolver

/// The allowlist DNS resolver on 127.0.0.1:53 and [::1]:53 (UDP and TCP).
///
/// For each query: adult blocklist → NXDOMAIN; not on the current allowlist → NXDOMAIN;
/// otherwise forward upstream, put every A/AAAA answer into pf's allow table, then reply.
final class DNSServer {
    private let box: PolicyBox
    private let pf: PFManager
    private let upstreamLock = NSLock()
    private var upstreamServers: [String]
    private var sources: [DispatchSourceRead] = []
    private let ioQueue = DispatchQueue(label: "intentmode.dns.io")
    private let work = DispatchQueue(label: "intentmode.dns.work", attributes: .concurrent)
    private let limiter = DispatchSemaphore(value: 48)

    init(box: PolicyBox, pf: PFManager, upstream: [String]) {
        self.box = box
        self.pf = pf
        self.upstreamServers = upstream
    }

    func setUpstream(_ s: [String]) {
        upstreamLock.lock(); upstreamServers = s; upstreamLock.unlock()
    }

    private var upstream: [String] {
        upstreamLock.lock(); defer { upstreamLock.unlock() }
        return upstreamServers
    }

    func start() throws {
        for (ip, v6) in [("127.0.0.1", false), ("::1", true)] {
            let u = try bind(ip: ip, v6: v6, stream: false)
            let t = try bind(ip: ip, v6: v6, stream: true)
            watchUDP(u)
            watchTCP(t)
        }
        Log.info("DNS resolver listening on 127.0.0.1:53 and [::1]:53")
    }

    private func bind(ip: String, v6: Bool, stream: Bool) throws -> Int32 {
        let fd = socket(v6 ? AF_INET6 : AF_INET, stream ? SOCK_STREAM : SOCK_DGRAM, 0)
        guard fd >= 0 else { throw ConfigError("socket() failed") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        if v6 { setsockopt(fd, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size)) }
        let r = Sock.withAddress(ip, port: 53) { Darwin.bind(fd, $0, $1) } ?? -1
        guard r == 0 else {
            let e = String(cString: strerror(errno))
            close(fd)
            throw ConfigError("cannot bind \(ip):53 (\(e)) — is another DNS server running?")
        }
        if stream { listen(fd, 64) }
        Sock.setBlocking(fd, false)
        return fd
    }

    private func watchUDP(_ fd: Int32) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                var buf = [UInt8](repeating: 0, count: 4096)
                var from = sockaddr_storage()
                var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) }
                }
                if n <= 0 { break }
                let query = Array(buf[0..<n])
                let peer = from
                let peerLen = fromLen
                self.limiter.wait()
                self.work.async {
                    defer { self.limiter.signal() }
                    guard let reply = self.handle(query) else { return }
                    var p = peer
                    _ = withUnsafePointer(to: &p) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, reply, reply.count, 0, $0, peerLen) }
                    }
                }
            }
        }
        src.resume()
        sources.append(src)
    }

    private func watchTCP(_ fd: Int32) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { break }
                Sock.setBlocking(c, true)
                Sock.setTimeout(c, 5)
                Sock.setNoSigPipe(c)
                self.work.async { self.serveTCP(c) }
            }
        }
        src.resume()
        sources.append(src)
    }

    private func serveTCP(_ c: Int32) {
        defer { close(c) }
        while let lenBytes = Sock.readExact(c, 2) {
            let len = Int(lenBytes[0]) << 8 | Int(lenBytes[1])
            guard len > 0, let q = Sock.readExact(c, len), let r = handle(q) else { return }
            guard Sock.writeAll(c, [UInt8(r.count >> 8), UInt8(r.count & 0xFF)] + r) else { return }
        }
    }

    /// Decides and answers one query. Returns nil to drop garbage.
    func handle(_ query: [UInt8]) -> [UInt8]? {
        guard let q = DNSMessage.parseQuestion(query) else { return nil }
        let policy = box.current
        guard policy.permits(q.name) else {
            return DNSMessage.makeResponse(query: query, question: q, rcode: DNSMessage.rcodeNXDomain)
        }
        if policy.kind == .learn { box.recordLearned(q.name) }
        // HTTPS/SVCB records can carry IP hints that would bypass our table; answer "no data" so
        // clients fall back to plain A/AAAA lookups.
        if q.qtype == DNSMessage.typeHTTPS || q.qtype == DNSMessage.typeSVCB {
            return DNSMessage.makeResponse(query: query, question: q, rcode: DNSMessage.rcodeNoError)
        }
        guard let reply = Upstream.query(query, servers: upstream) else {
            return DNSMessage.makeResponse(query: query, question: q, rcode: DNSMessage.rcodeServFail)
        }
        let addrs = DNSMessage.addresses(in: reply)
        if !addrs.isEmpty { pf.allow(addrs, generation: policy.generation) }
        return reply
    }
}
