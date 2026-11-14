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

final class SafeSearchTests: XCTestCase {
    func testTargets() {
        XCTAssertEqual(SafeSearch.target(for: "www.google.com"), "forcesafesearch.google.com")
        XCTAssertEqual(SafeSearch.target(for: "google.de."), "forcesafesearch.google.com")
        XCTAssertEqual(SafeSearch.target(for: "www.google.co.uk"), "forcesafesearch.google.com")
        XCTAssertNil(SafeSearch.target(for: "docs.google.com"))
        XCTAssertNil(SafeSearch.target(for: "accounts.google.com"))
        XCTAssertNil(SafeSearch.target(for: "google.example.org"))
        XCTAssertEqual(SafeSearch.target(for: "www.youtube.com"), "restrict.youtube.com")
        XCTAssertEqual(SafeSearch.target(for: "www.bing.com"), "strict.bing.com")
        XCTAssertEqual(SafeSearch.target(for: "duckduckgo.com"), "safe.duckduckgo.com")
    }

    func testAnswerUnderOriginalName() {
        let q = DNSMessage.makeQuery(id: 42, name: "www.google.com", qtype: DNSMessage.typeA)
        let question = DNSMessage.parseQuestion(q)!
        let recs = [DNSMessage.Record(type: 1, ttl: 300, rdata: [216, 239, 38, 120])]
        let r = DNSMessage.makeAnswer(query: q, question: question, records: recs)
        XCTAssertEqual(DNSMessage.id(r), 42)
        XCTAssertEqual(DNSMessage.rcode(r), 0)
        XCTAssertEqual(DNSMessage.addresses(in: r), [DNSMessage.Address(ip: "216.239.38.120", ttl: 300)])
        XCTAssertEqual(DNSMessage.addressRecords(in: r).count, 1)
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

    func testOpenWebMode() throws {
        let json = """
        {"domain_groups": {"distraction": ["reddit.com", "youtube.com"]},
         "modes": [{"id": "research", "name": "Research", "apps": [{"bundle_id": "com.google.Chrome"}],
                    "open_web": true, "blocked_domains": ["@distraction"], "minutes": 15,
                    "daily_limit": 2, "weekly_limit": 5, "intent_min_words": 12, "start_delay_seconds": 30}]}
        """
        let c = try IntentConfig.parse(Data(json.utf8))
        let m = c.mode("research")!
        XCTAssertTrue(m.isOpenWeb)
        XCTAssertEqual(m.weeklyLimit, 5)
        XCTAssertEqual(c.intentMinWords(for: m), 12)
        let blocked = DomainMatcher(entries: c.blockedDomains(for: m))
        XCTAssertTrue(blocked.matches("old.reddit.com"))
        XCTAssertTrue(blocked.matches("www.youtube.com"))
        XCTAssertFalse(blocked.matches("autoscout24.de"))

        let bad = """
        {"modes": [{"id": "x", "name": "x", "apps": [{"bundle_id": "a"}], "open_web": true, "domains": ["a.com"], "minutes": 5},
                   {"id": "y", "name": "y", "apps": [{"bundle_id": "a"}], "minutes": 5}]}
        """
        XCTAssertThrowsError(try IntentConfig.parse(Data(bad.utf8))) { e in
            XCTAssertTrue("\(e)".contains("doesn't use 'domains'"))
            XCTAssertTrue("\(e)".contains("domains is empty"))
        }
    }

    func testDefaultConfigFileParses() throws {
        // Tests run from the package root.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/config.default.json")
        let c = try IntentConfig.load(path: url.path)
        XCTAssertNotNil(c.mode("claude"))
        XCTAssertNotNil(c.mode("journal"))
        XCTAssertEqual(c.mode("research")?.isOpenWeb, true)
        XCTAssertEqual(c.mode("research")?.startDelaySeconds, 60)
        let always = DomainMatcher(entries: c.expand(c.alwaysBlockedDomains))
        XCTAssertTrue(always.matches("mangafire.to"))
        XCTAssertTrue(always.matches("dns.google"))
        XCTAssertFalse(always.matches("github.com"))
        let anchor = PFRules.anchor(config: c, restrictUpstreamToRoot: true)
        XCTAssertTrue(anchor.contains("block return out quick all"))
        XCTAssertTrue(anchor.contains("user root"))
    }
}

final class BedtimeTests: XCTestCase {
    func testWindowAcrossMidnight() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let b = Bedtime(start: "23:00", end: "06:00", allowedModes: ["journal"])
        func at(_ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: h, minute: m))! }
        XCTAssertNil(b.endIfActive(at: at(22, 59), calendar: cal))
        XCTAssertEqual(b.endIfActive(at: at(23, 0), calendar: cal), cal.date(byAdding: .hour, value: 7, to: at(23, 0)))
        XCTAssertEqual(b.endIfActive(at: at(2, 30), calendar: cal), at(6, 0))
        XCTAssertNil(b.endIfActive(at: at(6, 0), calendar: cal))
        XCTAssertEqual(b.nextStart(after: at(22, 40), calendar: cal), at(23, 0))
        XCTAssertEqual(b.nextStart(after: at(23, 30), calendar: cal), cal.date(byAdding: .day, value: 1, to: at(23, 0)))
        XCTAssertFalse(Bedtime(start: "25:00", end: "06:00", allowedModes: []).isValid)
    }
}

final class ScheduleTests: XCTestCase {
    func testSundayWindow() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let w = ScheduleWindow(days: ["sun"], start: "10:00", end: "17:00")
        // 2026-11-15 is a Sunday, 2026-11-14 a Saturday.
        func at(_ d: Int, _ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))! }
        XCTAssertTrue(w.isValid)
        XCTAssertNil(w.endIfActive(at: at(14, 12, 0), calendar: cal))
        XCTAssertNil(w.endIfActive(at: at(15, 9, 59), calendar: cal))
        XCTAssertEqual(w.endIfActive(at: at(15, 10, 0), calendar: cal), at(15, 17, 0))
        XCTAssertEqual(w.endIfActive(at: at(15, 16, 45), calendar: cal), at(15, 17, 0))
        XCTAssertNil(w.endIfActive(at: at(15, 17, 0), calendar: cal))
        XCTAssertEqual(w.label, "Sun 10:00–17:00")
        XCTAssertFalse(ScheduleWindow(days: ["sunday"], start: "10:00", end: "17:00").isValid)
    }
}

final class StatsTests: XCTestCase {
    func testWeekOverview() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        // Week of Monday 2026-11-09; "now" is Saturday 2026-11-14 12:00 UTC.
        let now = ISO8601DateFormatter().date(from: "2026-11-14T12:00:00Z")!
        let log = """
        {"event":"session_end","mode":"journal","intent":"write about the week","started":"2026-11-10T08:00:00Z","at":"2026-11-10T08:20:00Z","extended":false,"ended_early":false}
        {"event":"session_end","mode":"research","intent":"car rental lisbon","started":"2026-11-14T09:00:00Z","at":"2026-11-14T09:25:00Z","extended":true,"ended_early":false}
        {"event":"session_end","mode":"open","intent":"update macos","started":"2026-11-12T20:00:00Z","at":"2026-11-12T20:05:00Z","extended":false,"ended_early":true}
        {"event":"session_end","mode":"journal","intent":"last week","started":"2026-11-05T08:00:00Z","at":"2026-11-05T08:30:00Z"}
        {"event":"escape_cancelled","at":"2026-11-13T10:00:00Z"}
        garbage line
        """
        let r = StatsBuilder.Running(mode: "claude", intent: "build stuff", started: now.addingTimeInterval(-600))
        let s = StatsBuilder.build(log: log, modeNames: ["journal": "Journal", "research": "Research", "open": "Open session", "claude": "Claude"],
                                   escapeModes: ["open"], escapeLimit: 3, running: r, now: now, calendar: cal)
        XCTAssertEqual(s.totalMinutes, 20 + 25 + 5 + 10)
        XCTAssertEqual(s.sessionCount, 4)
        XCTAssertEqual(s.perMode.first?.id, "research")
        XCTAssertEqual(s.perDayMinutes, [0, 20, 0, 5, 0, 35, 0])
        XCTAssertEqual(s.openSessionsUsed, 1)
        XCTAssertEqual(s.openRequestsCancelled, 1)
        XCTAssertEqual(s.extensions, 1)
        XCTAssertEqual(s.endedEarly, 1)
        XCTAssertEqual(s.longest.map { $0.minutes }, [25, 20, 10])
        XCTAssertEqual(s.lastWeekMinutes, 30)
        let t = StatsBuilder.today(s, now: now, calendar: cal)
        XCTAssertEqual(t.minutes, 35)
        XCTAssertEqual(t.sessions, 2)
    }
}

final class ConfigUpgraderTests: XCTestCase {
    func testUpgradeKeepsUserEdits() {
        let user: [String: Any] = [
            "modes": [["id": "claude", "minutes": 30, "daily_limit": 5], ["id": "journal", "minutes": 20]],
            "domain_groups": ["mine": ["a.com"]],
            "locked_allowed_domains": ["=time.apple.com"],
        ]
        let defaults: [String: Any] = [
            "modes": [["id": "claude", "minutes": 10, "daily_limit": 2], ["id": "journal"], ["id": "maintenance", "name": "Maintenance"], ["id": "deleted"]],
            "domain_groups": ["mine": ["b.com"], "apple_swupdate": ["=swscan.apple.com"]],
            "locked_allowed_domains": ["=time.apple.com", "@apple_swupdate"],
            "idle_end_minutes": 5,
        ]
        var state = ConfigUpgrader.State()
        state.knownDefaultModes = ["claude", "journal", "deleted"]   // "deleted" was removed by the user earlier
        let (out, notes, st) = ConfigUpgrader.upgrade(user: user, defaults: defaults, state: state)
        let modes = out["modes"] as! [[String: Any]]
        let claude = modes.first { ($0["id"] as? String) == "claude" }!
        XCTAssertEqual(claude["minutes"] as? Int, 10)        // was still the old default 30
        XCTAssertEqual(claude["daily_limit"] as? Int, 5)     // user's own value is kept
        XCTAssertTrue(modes.contains { ($0["id"] as? String) == "maintenance" })
        XCTAssertFalse(modes.contains { ($0["id"] as? String) == "deleted" })
        XCTAssertEqual((out["domain_groups"] as! [String: Any])["mine"] as? [String], ["a.com"])
        XCTAssertNotNil((out["domain_groups"] as! [String: Any])["apple_swupdate"])
        XCTAssertEqual(out["locked_allowed_domains"] as? [String], ["=time.apple.com", "@apple_swupdate"])
        XCTAssertEqual(out["idle_end_minutes"] as? Int, 5)
        XCTAssertFalse(notes.isEmpty)
        // Running again changes nothing.
        let (_, notes2, _) = ConfigUpgrader.upgrade(user: out, defaults: defaults, state: st)
        XCTAssertEqual(notes2, [])
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
