import Foundation
import Darwin
import IntentCore

/// Listens on /var/run/intentmode.sock. One JSON request line in, one JSON response line out.
/// The socket is world-connectable; each handler checks the caller's uid (from the kernel) itself.
final class ControlServer {
    private let handler: (IPCRequest, uid_t) -> IPCResponse
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let acceptQ = DispatchQueue(label: "intentmode.control")

    init(handler: @escaping (IPCRequest, uid_t) -> IPCResponse) { self.handler = handler }

    func start() throws {
        let path = Paths.socket
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConfigError("control socket() failed") }
        var addr = try UnixSocket.makeAddress(path)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0 else { throw ConfigError("cannot bind \(path): \(String(cString: strerror(errno)))") }
        chmod(path, 0o666)
        listen(fd, 32)
        Sock.setBlocking(fd, false)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQ)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let c = accept(self.fd, nil, nil)
                if c < 0 { break }
                DispatchQueue.global().async { self.serve(c) }
            }
        }
        src.resume()
        source = src
        Log.info("control socket listening at \(path)")
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        Sock.setBlocking(c, true)
        Sock.setNoSigPipe(c)
        UnixSocket.setTimeouts(c, seconds: 10)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0 else { return }
        let response: IPCResponse
        do {
            let line = try UnixSocket.readLine(c, maxBytes: 64 * 1024)
            let req = try JSONDecoder().decode(IPCRequest.self, from: line)
            response = handler(req, uid)
        } catch {
            response = .fail("bad request: \(error)")
        }
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        try? UnixSocket.writeAll(c, data)
    }
}
