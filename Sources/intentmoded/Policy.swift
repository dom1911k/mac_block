import Foundation
import IntentCore

/// What is allowed right now. Immutable; the daemon swaps in a new one on every state change.
final class Policy {
    enum Kind: String { case locked, session, learn }

    let kind: Kind
    /// Bumped on every change that must invalidate the pf table (session start/end).
    let generation: Int
    let allow: DomainMatcher
    /// The shared always-blocked list (adult lists, bypass sites). Checked first, in every mode.
    let block: Blocklist
    /// Extra names blocked only in this mode (an open-web mode's blocked_domains).
    let modeBlock: DomainMatcher
    let allowAll: Bool
    let apps: [AppRule]
    let safeSearch: Bool

    init(kind: Kind, generation: Int, allow: DomainMatcher, block: Blocklist, modeBlock: DomainMatcher = DomainMatcher(),
         allowAll: Bool, apps: [AppRule], safeSearch: Bool) {
        self.kind = kind; self.generation = generation; self.allow = allow; self.block = block
        self.modeBlock = modeBlock; self.allowAll = allowAll; self.apps = apps; self.safeSearch = safeSearch
    }

    func permits(_ name: String) -> Bool {
        if block.blocks(name) || modeBlock.matches(name) { return false }
        return allowAll || allow.matches(name)
    }
}

/// The big always-on blocklist, shared by reference between policies (it has ~500k entries).
final class Blocklist {
    let matcher: DomainMatcher
    let exceptions: Set<String>
    init(matcher: DomainMatcher = DomainMatcher(), exceptions: Set<String> = []) {
        self.matcher = matcher; self.exceptions = exceptions
    }
    var count: Int { matcher.count }
    func blocks(_ name: String) -> Bool {
        matcher.matches(name) && !exceptions.contains(DomainMatcher.normalize(name))
    }
}

/// Thread-safe holder read by the DNS threads on every query.
final class PolicyBox {
    private let lock = NSLock()
    private var policy: Policy
    private var learned = Set<String>()

    init(_ p: Policy) { policy = p }

    var current: Policy {
        lock.lock(); defer { lock.unlock() }
        return policy
    }

    func set(_ p: Policy) {
        lock.lock(); policy = p; lock.unlock()
    }

    func recordLearned(_ name: String) {
        lock.lock(); learned.insert(name); lock.unlock()
    }

    func takeLearned() -> Set<String> {
        lock.lock(); defer { learned.removeAll(); lock.unlock() }
        return learned
    }
}
