import Foundation
import IntentCore

/// What is allowed right now. Immutable; the daemon swaps in a new one on every state change.
final class Policy {
    enum Kind: String { case locked, session, learn }

    let kind: Kind
    /// Bumped on every change that must invalidate the pf table (session start/end).
    let generation: Int
    let allow: DomainMatcher
    /// Always-blocked names (adult list). Checked before `allow`, in every mode.
    let block: DomainMatcher
    let allowAll: Bool
    let apps: [AppRule]

    init(kind: Kind, generation: Int, allow: DomainMatcher, block: DomainMatcher, allowAll: Bool, apps: [AppRule]) {
        self.kind = kind; self.generation = generation; self.allow = allow
        self.block = block; self.allowAll = allowAll; self.apps = apps
    }

    func permits(_ name: String) -> Bool {
        if block.matches(name) { return false }
        return allowAll || allow.matches(name)
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
