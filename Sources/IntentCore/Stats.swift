import Foundation

/// Builds the usage overview from sessions.jsonl (one JSON event per line, written by the daemon).
public enum StatsBuilder {
    public struct Running {
        public let mode: String
        public let intent: String
        public let started: Date
        public init(mode: String, intent: String, started: Date) { self.mode = mode; self.intent = intent; self.started = started }
    }

    static func weekStart(_ d: Date, _ cal: Calendar) -> Date {
        var c = Calendar(identifier: .iso8601); c.timeZone = cal.timeZone
        return c.dateInterval(of: .weekOfYear, for: d)?.start ?? c.startOfDay(for: d)
    }

    public static func build(log: String, modeNames: [String: String], escapeModes: Set<String>, escapeLimit: Int?,
                             running: Running?, now: Date = Date(), calendar: Calendar = .current) -> WeekStats {
        let iso = ISO8601DateFormatter()
        let start = weekStart(now, calendar)
        let lastStart = calendar.date(byAdding: .day, value: -7, to: start)!
        var sessions: [SessionSummary] = []
        var lastWeekSeconds = 0.0
        var cancelled = 0

        for line in log.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let event = obj["event"] as? String,
                  let at = (obj["at"] as? String).flatMap({ iso.date(from: $0) }) else { continue }
            if event == "escape_cancelled", at >= start { cancelled += 1 }
            guard event == "session_end", let mode = obj["mode"] as? String,
                  let started = (obj["started"] as? String).flatMap({ iso.date(from: $0) }) else { continue }
            let seconds = max(0, at.timeIntervalSince(started))
            if started >= start {
                sessions.append(SessionSummary(mode: mode, modeName: modeNames[mode] ?? mode,
                                               minutes: Int((seconds / 60).rounded()),
                                               intent: obj["intent"] as? String ?? "",
                                               started: started.timeIntervalSince1970,
                                               extended: obj["extended"] as? Bool ?? false,
                                               endedEarly: obj["ended_early"] as? Bool ?? false))
            } else if started >= lastStart {
                lastWeekSeconds += seconds
            }
        }
        if let r = running, r.started >= start {
            sessions.append(SessionSummary(mode: r.mode, modeName: (modeNames[r.mode] ?? r.mode) + " (now)",
                                           minutes: Int((now.timeIntervalSince(r.started) / 60).rounded()),
                                           intent: r.intent, started: r.started.timeIntervalSince1970,
                                           extended: false, endedEarly: false))
        }
        sessions.sort { $0.started > $1.started }

        var perMode: [String: (Int, Int)] = [:]
        var perDay = [Int](repeating: 0, count: 7)
        var iso8601 = Calendar(identifier: .iso8601); iso8601.timeZone = calendar.timeZone
        for s in sessions {
            let modeKey = s.mode
            let cur = perMode[modeKey] ?? (0, 0)
            perMode[modeKey] = (cur.0 + s.minutes, cur.1 + 1)
            let wd = iso8601.component(.weekday, from: Date(timeIntervalSince1970: s.started))  // 1 = Sunday
            perDay[(wd + 5) % 7] += s.minutes                                                  // Monday = 0
        }
        let usage = perMode.map { ModeUsage(id: $0.key, name: modeNames[$0.key] ?? $0.key, minutes: $0.value.0, sessions: $0.value.1) }
            .sorted { $0.minutes > $1.minutes }
        return WeekStats(weekStart: start.timeIntervalSince1970,
                         totalMinutes: sessions.reduce(0) { $0 + $1.minutes },
                         sessionCount: sessions.count,
                         perMode: usage,
                         perDayMinutes: perDay,
                         openSessionsUsed: sessions.filter { escapeModes.contains($0.mode) }.count,
                         openSessionsLimit: escapeLimit,
                         openRequestsCancelled: cancelled,
                         extensions: sessions.filter { $0.extended }.count,
                         endedEarly: sessions.filter { $0.endedEarly }.count,
                         longest: Array(sessions.sorted { $0.minutes > $1.minutes }.prefix(3)),
                         sessions: sessions,
                         lastWeekMinutes: Int((lastWeekSeconds / 60).rounded()))
    }

    /// Minutes and session count since local midnight (including a running session).
    public static func today(_ stats: WeekStats, now: Date = Date(), calendar: Calendar = .current) -> (minutes: Int, sessions: Int) {
        let midnight = calendar.startOfDay(for: now).timeIntervalSince1970
        let todays = stats.sessions.filter { $0.started >= midnight }
        return (todays.reduce(0) { $0 + $1.minutes }, todays.count)
    }
}
