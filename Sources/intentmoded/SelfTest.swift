import Foundation
import Darwin
import IntentCore

/// `intentmoded --self-test [--config path]`: a quick check that this build works with a config.
/// Run by build.sh, by install.sh, and by the updater before a new version is activated.
enum SelfTest {
    static func main(_ args: [String]) -> Int32 {
        var path = Paths.config
        if let i = args.firstIndex(of: "--config"), i + 1 < args.count { path = args[i + 1] }
        print("intentmoded \(BuildInfo.version) self-test (config: \(path))")
        func fail(_ m: String) -> Int32 { print("SELF-TEST FAILED: \(m)"); return 1 }

        let config: IntentConfig
        do { config = try IntentConfig.load(path: path) } catch { return fail("\(error)") }
        print("  config OK: \(config.modes.count) modes (\(config.modes.map { $0.id }.joined(separator: ", ")))")

        let q = DNSMessage.makeQuery(id: 0x1234, name: "api.claude.ai", qtype: DNSMessage.typeA)
        guard let parsed = DNSMessage.parseQuestion(q), parsed.name == "api.claude.ai" else { return fail("DNS parser") }
        let nx = DNSMessage.makeResponse(query: q, question: parsed, rcode: DNSMessage.rcodeNXDomain)
        guard DNSMessage.rcode(nx) == 3 else { return fail("DNS response builder") }
        guard DomainMatcher(entries: ["claude.ai"]).matches("api.claude.ai"),
              !DomainMatcher(entries: ["=docs.google.com"]).matches("www.google.com") else { return fail("domain matcher") }
        print("  DNS + matcher OK")

        let anchor = PFRules.anchor(config: config, restrictUpstreamToRoot: config.pfRestrictUpstreamToRoot)
        if getuid() == 0 {
            // -n = parse only, nothing is loaded.
            let r = run("/sbin/pfctl", ["-n", "-a", Paths.pfAnchor, "-f", "-"], input: anchor)
            guard r.ok else { return fail("pf rules don't parse:\n\(r.err)\n--- rules ---\n\(anchor)") }
            print("  pf rules parse OK")
        } else {
            print("  pf syntax check skipped (needs root)")
        }
        print("SELF-TEST OK")
        return 0
    }
}
