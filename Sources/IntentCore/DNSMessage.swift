import Foundation

public struct DNSQuestion: Equatable {
    public let id: UInt16
    public let name: String
    public let qtype: UInt16
    public let qclass: UInt16
    /// Byte offset just past the question section.
    public let questionEnd: Int
}

/// Minimal DNS wire-format handling. We never re-encode answers: allowed queries are
/// forwarded byte-for-byte and the upstream reply is passed back unchanged.
public enum DNSMessage {
    public static let typeA: UInt16 = 1
    public static let typeCNAME: UInt16 = 5
    public static let typeAAAA: UInt16 = 28
    public static let typeSVCB: UInt16 = 64
    public static let typeHTTPS: UInt16 = 65

    public static let rcodeNoError: UInt8 = 0
    public static let rcodeServFail: UInt8 = 2
    public static let rcodeNXDomain: UInt8 = 3

    public struct Address: Equatable, Hashable {
        public let ip: String
        public let ttl: UInt32
        public init(ip: String, ttl: UInt32) { self.ip = ip; self.ttl = ttl }
    }

    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }

    /// Reads a (possibly compressed) name. Returns the lowercased dotted name and the offset after it.
    public static func readName(_ b: [UInt8], at start: Int) -> (name: String, next: Int)? {
        var labels: [String] = []
        var o = start
        var next: Int?
        var jumps = 0
        var total = 0
        while true {
            guard o < b.count else { return nil }
            let len = Int(b[o])
            if len == 0 { o += 1; break }
            if len & 0xC0 == 0xC0 {
                guard o + 1 < b.count else { return nil }
                let ptr = (len & 0x3F) << 8 | Int(b[o + 1])
                if next == nil { next = o + 2 }
                jumps += 1
                guard jumps <= 32, ptr < b.count else { return nil }
                o = ptr
                continue
            }
            guard len & 0xC0 == 0, o + 1 + len <= b.count else { return nil }
            labels.append(String(decoding: b[(o + 1)..<(o + 1 + len)], as: UTF8.self))
            total += len + 1
            guard total <= 255 else { return nil }
            o += 1 + len
        }
        return (labels.joined(separator: ".").lowercased(), next ?? o)
    }

    /// Parses a query with exactly one question. Returns nil for responses or malformed packets.
    public static func parseQuestion(_ b: [UInt8]) -> DNSQuestion? {
        guard b.count >= 12 else { return nil }
        let flags = u16(b, 2)
        guard flags & 0x8000 == 0 else { return nil }          // QR set = it's a response
        guard u16(b, 4) == 1 else { return nil }               // exactly one question
        guard let (name, next) = readName(b, at: 12), next + 4 <= b.count else { return nil }
        return DNSQuestion(id: u16(b, 0), name: name, qtype: u16(b, next), qclass: u16(b, next + 2), questionEnd: next + 4)
    }

    /// Builds an empty reply (NXDOMAIN, SERVFAIL or NODATA) that echoes the question.
    public static func makeResponse(query: [UInt8], question: DNSQuestion, rcode: UInt8) -> [UInt8] {
        var r = Array(query[0..<question.questionEnd])
        let rd = query[2] & 0x01
        let opcode = query[2] & 0x78
        r[2] = 0x80 | opcode | rd                // QR=1, AA=0, TC=0
        r[3] = 0x80 | (rcode & 0x0F)             // RA=1
        r[4] = 0; r[5] = 1                       // QDCOUNT=1
        for i in 6..<12 { r[i] = 0 }             // AN/NS/AR = 0
        return r
    }

    public static func makeQuery(id: UInt16, name: String, qtype: UInt16) -> [UInt8] {
        var b: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8.prefix(63))
            b.append(UInt8(bytes.count))
            b.append(contentsOf: bytes)
        }
        b.append(0)
        b.append(contentsOf: [UInt8(qtype >> 8), UInt8(qtype & 0xFF), 0, 1])
        return b
    }

    public static func id(_ b: [UInt8]) -> UInt16? { b.count >= 2 ? u16(b, 0) : nil }
    public static func isResponse(_ b: [UInt8]) -> Bool { b.count >= 12 && b[2] & 0x80 != 0 }
    public static func isTruncated(_ b: [UInt8]) -> Bool { b.count >= 4 && b[2] & 0x02 != 0 }
    public static func rcode(_ b: [UInt8]) -> UInt8 { b.count >= 4 ? b[3] & 0x0F : 0xFF }

    /// All A/AAAA records in the answer section (including those at the end of CNAME chains).
    /// Unusable addresses (0.0.0.0, ::, loopback) are dropped: Cloudflare's 1.1.1.3 answers
    /// blocked adult domains with 0.0.0.0.
    public static func addresses(in b: [UInt8]) -> [Address] {
        guard b.count >= 12 else { return [] }
        let qd = Int(u16(b, 4))
        let an = Int(u16(b, 6))
        var o = 12
        for _ in 0..<qd {
            guard let (_, n) = readName(b, at: o), n + 4 <= b.count else { return [] }
            o = n + 4
        }
        var out: [Address] = []
        for _ in 0..<an {
            guard let (_, n) = readName(b, at: o), n + 10 <= b.count else { break }
            let type = u16(b, n)
            let ttl = u32(b, n + 4)
            let rdlen = Int(u16(b, n + 8))
            let rd = n + 10
            guard rd + rdlen <= b.count else { break }
            if type == typeA && rdlen == 4 {
                let ip = "\(b[rd]).\(b[rd + 1]).\(b[rd + 2]).\(b[rd + 3])"
                if b[rd] != 0 && b[rd] != 127 { out.append(Address(ip: ip, ttl: ttl)) }
            } else if type == typeAAAA && rdlen == 16 {
                let groups = (0..<8).map { u16(b, rd + 2 * $0) }
                let allZero = groups.allSatisfy { $0 == 0 }
                let loopback = groups.dropLast().allSatisfy { $0 == 0 } && groups.last == 1
                if !allZero && !loopback {
                    out.append(Address(ip: groups.map { String($0, radix: 16) }.joined(separator: ":"), ttl: ttl))
                }
            }
            o = rd + rdlen
        }
        return out
    }
}
