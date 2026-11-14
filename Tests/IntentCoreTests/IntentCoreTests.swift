import XCTest
@testable import IntentCore

final class DomainMatcherTests: XCTestCase {
    func testSuffixAndExact() {
        let m = DomainMatcher(entries: ["claude.ai", "=docs.google.com", "*.github.com", "Example.ORG.", "# comment"])
        XCTAssertTrue(m.matches("claude.ai"))
        XCTAssertTrue(m.matches("api.claude.ai"))
        XCTAssertTrue(m.matches("CLAUDE.AI."))
        XCTAssertFalse(m.matches("notclaude.ai"))
        XCTAssertFalse(m.matches("claude.ai.evil.com"))
        XCTAssertTrue(m.matches("docs.google.com"))
        XCTAssertFalse(m.matches("www.docs.google.com"))
        XCTAssertFalse(m.matches("google.com"))
        XCTAssertTrue(m.matches("github.com"))
        XCTAssertTrue(m.matches("raw.github.com"))
        XCTAssertTrue(m.matches("example.org"))
        XCTAssertFalse(m.matches(""))
        XCTAssertFalse(DomainMatcher().matches("anything.com"))
        XCTAssertTrue(DomainMatcher(entries: ["*"]).matches("anything.com"))
    }

    func testListFileParsing() {
        let text = "# StevenBlack\n0.0.0.0 bad.example\n127.0.0.1 localhost\nplain.example # tail\n\n0.0.0.0 0.0.0.0\n"
        XCTAssertEqual(DomainMatcher.entries(fromListFile: text), ["bad.example", "plain.example"])
    }
}

final class DNSTests: XCTestCase {
    func testQueryRoundTrip() {
        let q = DNSMessage.makeQuery(id: 0xBEEF, name: "Sub.Example.com", qtype: DNSMessage.typeAAAA)
        let parsed = DNSMessage.parseQuestion(q)
        XCTAssertEqual(parsed?.id, 0xBEEF)
        XCTAssertEqual(parsed?.name, "sub.example.com")
        XCTAssertEqual(parsed?.qtype, 28)
        XCTAssertEqual(parsed?.questionEnd, q.count)
    }

    func testNXDomainResponse() {
        let q = DNSMessage.makeQuery(id: 7, name: "reddit.com", qtype: 1)
        let question = DNSMessage.parseQuestion(q)!
        let r = DNSMessage.makeResponse(query: q, question: question, rcode: DNSMessage.rcodeNXDomain)
        XCTAssertTrue(DNSMessage.isResponse(r))
        XCTAssertEqual(DNSMessage.rcode(r), 3)
        XCTAssertEqual(DNSMessage.id(r), 7)
        XCTAssertNil(DNSMessage.parseQuestion(r)) // it's a response now
    }

    func testAddressesWithCompressionAndCNAME() {
        // Response for www.example.com: CNAME → example.net (via pointer), then A 93.184.216.34 and AAAA 2606:2800::1, A 0.0.0.0 (dropped)
        var b = DNSMessage.makeQuery(id: 1, name: "www.example.com", qtype: 1)
        b[2] = 0x81; b[3] = 0x80
        b[6] = 0; b[7] = 4 // ANCOUNT = 4
        // CNAME: name ptr to 12, type 5, class 1, ttl 60, rdlen, rdata "example.net"
        let target: [UInt8] = [7] + Array("example".utf8) + [3] + Array("net".utf8) + [0]
        b += [0xC0, 12, 0, 5, 0, 1, 0, 0, 0, 60, 0, UInt8(target.count)] + target
        let targetOffset = b.count - target.count
        // A record for the CNAME target (pointer to targetOffset)
        b += [0xC0, UInt8(targetOffset), 0, 1, 0, 1, 0, 0, 1, 0x2C, 0, 4, 93, 184, 216, 34]
        // AAAA 2606:2800:0:0:0:0:0:1
        b += [0xC0, UInt8(targetOffset), 0, 28, 0, 1, 0, 0, 0, 30, 0, 16, 0x26, 0x06, 0x28, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        // A 0.0.0.0 (Cloudflare family filter block) — must be ignored
        b += [0xC0, UInt8(targetOffset), 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 0, 0, 0, 0]
        let addrs = DNSMessage.addresses(in: b)
        XCTAssertEqual(addrs, [
            DNSMessage.Address(ip: "93.184.216.34", ttl: 300),
            DNSMessage.Address(ip: "2606:2800:0:0:0:0:0:1", ttl: 30),
        ])
    }

    func testMalformedDoesNotCrash() {
        XCTAssertNil(DNSMessage.parseQuestion([1, 2, 3]))
        XCTAssertEqual(DNSMessage.addresses(in: [0, 1, 0x81, 0x80, 0, 1, 0, 5, 0, 0, 0, 0, 0xC0, 12]), [])
        // pointer loop
        let loop: [UInt8] = [0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 12, 0, 1, 0, 1]
        XCTAssertNil(DNSMessage.parseQuestion(loop))
    }
}

final class ConfigTests: XCTestCase {
    let json = """
    {
      "_readme": "ignored",
      "flags": {"claude_mode_allow_google_search": false, "other_flag": true},
      "domain_groups": {"google_signin": ["=accounts.google.com", "@nested"], "nested": ["=ssl.gstatic.com"], "search": ["=www.google.com"]},
      "session_allowed_domains": ["=ocsp.apple.com"],
      "modes": [
        {"id": "claude", "name": "Claude", "apps": [{"bundle_id": "com.google.Chrome", "team_id": "EQHXZ8M8AV"}],
         "domains": ["claude.ai", "@google_signin"], "minutes": 30, "daily_limit": 3,
         "conditional_domains": [{"flag": "claude_mode_allow_google_search", "domains": ["@search"]},
                                 {"flag": "other_flag", "domains": ["=extra.example"]}]}
      ]
    }
    """

    func testParseAndExpand() throws {
        let c = try IntentConfig.parse(Data(json.utf8))
        XCTAssertEqual(c.intentMinWords, 8) // default
        XCTAssertEqual(c.flags["claude_mode_allow_google_search"], false) // snake_case dictionary keys kept
        let m = c.mode("claude")!
        XCTAssertEqual(m.apps.first?.teamId, "EQHXZ8M8AV")
        XCTAssertEqual(c.domains(for: m).sorted(),
                       ["=accounts.google.com", "=extra.example", "=ocsp.apple.com", "=ssl.gstatic.com", "claude.ai"])
    }

    func testValidation() {
        let bad = """
        {"modes": [{"id": "a b", "name": "x", "apps": [], "domains": ["@nope", "*"], "minutes": 0}], "upstream_dns": ["not-an-ip"]}
        """
        XCTAssertThrowsError(try IntentConfig.parse(Data(bad.utf8))) { e in
            let s = "\(e)"
            XCTAssertTrue(s.contains("not an IP"))
            XCTAssertTrue(s.contains("unknown domain group"))
            XCTAssertTrue(s.contains("apps is empty"))
        }
    }

    func testDefaultConfigFileParses() throws {
        // Tests run from the package root.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/config.default.json")
        let c = try IntentConfig.load(path: url.path)
        XCTAssertNotNil(c.mode("claude"))
        XCTAssertNotNil(c.mode("journal"))
        let anchor = PFRules.anchor(config: c, restrictUpstreamToRoot: true)
        XCTAssertTrue(anchor.contains("block return out quick all"))
        XCTAssertTrue(anchor.contains("user root"))
    }
}

final class MiscTests: XCTestCase {
    func testVersions() {
        XCTAssertTrue(VersionCompare.isNewer("0.1.1", than: "0.1.0"))
        XCTAssertTrue(VersionCompare.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(VersionCompare.isNewer("0.1.0", than: "0.1"))
        XCTAssertFalse(VersionCompare.isNewer("abc", than: "0.1"))
    }

    func testWordCount() {
        XCTAssertEqual(TextUtil.wordCount("  fix the  login bug in my app  "), 7)
        XCTAssertEqual(TextUtil.wordCount("- - - ok"), 1)
    }
}
