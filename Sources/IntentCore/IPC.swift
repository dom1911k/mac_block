import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The daemon listens on a Unix domain socket (Paths.socket). Each connection carries one
// request line of JSON and gets one response line back. The daemon learns the caller's
// user ID from the kernel (getpeereid), so admin-only commands require `sudo`.

public struct IPCRequest: Codable {
    public var cmd: String
    public var mode: String?
    public var intent: String?
    public var reason: String?
    public var path: String?
    public var apply: Bool?
    public var pid: Int32?
    public var username: String?
    public var password: String?

    public init(cmd: String, mode: String? = nil, intent: String? = nil, reason: String? = nil,
                path: String? = nil, apply: Bool? = nil, pid: Int32? = nil,
                username: String? = nil, password: String? = nil) {
        self.cmd = cmd; self.mode = mode; self.intent = intent; self.reason = reason
        self.path = path; self.apply = apply; self.pid = pid
        self.username = username; self.password = password
    }
}

public struct ModeStatus: Codable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var minutes: Int
    public var dailyLimit: Int?
    public var usedToday: Int
    public var available: Bool
    public var unavailableReason: String?

    public init(id: String, name: String, description: String?, minutes: Int, dailyLimit: Int?,
                usedToday: Int, available: Bool, unavailableReason: String?) {
        self.id = id; self.name = name; self.description = description; self.minutes = minutes
        self.dailyLimit = dailyLimit; self.usedToday = usedToday; self.available = available
        self.unavailableReason = unavailableReason
    }
}

public struct DaemonStatus: Codable {
    /// "locked", "session" or "learn"
    public var state: String
    public var modeId: String?
    public var modeName: String?
    public var intent: String?
    /// Seconds since 1970 (for display only; the daemon keeps the real timer).
    public var endsAt: Double?
    public var remainingSeconds: Int?
    public var warning: Bool
    /// "available", "waiting", "ready", "used" or "unavailable"
    public var extensionState: String
    public var extensionReadyIn: Int?
    public var extended: Bool
    public var version: String
    public var devBuild: Bool
    public var modes: [ModeStatus]
    public var intentMinWords: Int
    public var extensionMinReasonWords: Int
    public var extensionMinutes: Int
    public var exempt: Bool
    public var notice: String?

    public init(state: String, modeId: String? = nil, modeName: String? = nil, intent: String? = nil,
                endsAt: Double? = nil, remainingSeconds: Int? = nil, warning: Bool = false,
                extensionState: String = "unavailable", extensionReadyIn: Int? = nil, extended: Bool = false,
                version: String, devBuild: Bool, modes: [ModeStatus], intentMinWords: Int,
                extensionMinReasonWords: Int, extensionMinutes: Int, exempt: Bool, notice: String?) {
        self.state = state; self.modeId = modeId; self.modeName = modeName; self.intent = intent
        self.endsAt = endsAt; self.remainingSeconds = remainingSeconds; self.warning = warning
        self.extensionState = extensionState; self.extensionReadyIn = extensionReadyIn; self.extended = extended
        self.version = version; self.devBuild = devBuild; self.modes = modes; self.intentMinWords = intentMinWords
        self.extensionMinReasonWords = extensionMinReasonWords; self.extensionMinutes = extensionMinutes
        self.exempt = exempt; self.notice = notice
    }
}

public struct IPCResponse: Codable {
    public var ok: Bool
    public var error: String?
    public var message: String?
    public var status: DaemonStatus?
    public var launch: [LaunchItem]?
    public var lines: [String]?

    public init(ok: Bool, error: String? = nil, message: String? = nil, status: DaemonStatus? = nil,
                launch: [LaunchItem]? = nil, lines: [String]? = nil) {
        self.ok = ok; self.error = error; self.message = message; self.status = status
        self.launch = launch; self.lines = lines
    }

    public static func fail(_ e: String) -> IPCResponse { IPCResponse(ok: false, error: e) }
    public static func success(_ m: String? = nil) -> IPCResponse { IPCResponse(ok: true, message: m) }
}

public struct SocketError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

public enum UnixSocket {
    #if os(Linux)
    static let streamType = Int32(SOCK_STREAM.rawValue)
    #else
    static let streamType = SOCK_STREAM
    #endif

    public static func makeAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        #if !os(Linux)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return addr
    }

    public static func setTimeouts(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
    }

    public static func connectTo(path: String, timeoutSeconds: Int) throws -> Int32 {
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw SocketError("socket() failed: \(errno)") }
        #if !os(Linux)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        setTimeouts(fd, seconds: timeoutSeconds)
        var addr = try makeAddress(path)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard r == 0 else {
            close(fd)
            throw SocketError("Cannot reach the Intent Mode daemon (\(String(cString: strerror(errno)))). Is it running?")
        }
        return fd
    }

    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = write(fd, base + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw SocketError("write failed: \(errno)")
                }
                off += n
            }
        }
    }

    /// Reads up to the first newline (excluded). Throws on timeout, EOF before newline, or oversize.
    public static func readLine(_ fd: Int32, maxBytes: Int = 1 << 20) throws -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError("read failed or timed out (\(errno))")
            }
            if n == 0 {
                if out.isEmpty { throw SocketError("connection closed") }
                return out
            }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                out.append(contentsOf: buf[0..<nl])
                return out
            }
            out.append(contentsOf: buf[0..<n])
            if out.count > maxBytes { throw SocketError("message too large") }
        }
    }
}

public enum IPCClient {
    public static func send(_ req: IPCRequest, timeoutSeconds: Int = 15, socketPath: String = Paths.socket) throws -> IPCResponse {
        let fd = try UnixSocket.connectTo(path: socketPath, timeoutSeconds: timeoutSeconds)
        defer { close(fd) }
        var data = try JSONEncoder().encode(req)
        data.append(0x0A)
        try UnixSocket.writeAll(fd, data)
        let line = try UnixSocket.readLine(fd)
        return try JSONDecoder().decode(IPCResponse.self, from: line)
    }
}
