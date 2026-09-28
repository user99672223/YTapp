import Foundation

public enum Formatters {
    /// 3723 -> "1:02:03", 65 -> "1:05"
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    public static func bitrate(_ bitsPerSecond: Int) -> String {
        if bitsPerSecond >= 1_000_000 { return String(format: "%.1f Mb/s", Double(bitsPerSecond) / 1_000_000) }
        return "\(bitsPerSecond / 1000) kb/s"
    }

    public static func bytes(_ count: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(count)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(count) B" : String(format: "%.1f", value) + " " + units[unit]
    }
}

/// Parses chapter timestamps from a video description ("0:00 Intro"). YouTube only shows
/// chapters when the first starts at 0:00 and there are at least three.
public enum ChapterParser {
    public static func chapters(fromDescription description: String, duration: Double? = nil) -> [Chapter] {
        var result: [Chapter] = []
        let pattern = #"^\s*[\[(]?((?:\d{1,2}:)?\d{1,2}:\d{2})[\])]?\s*[-–—:|]?\s*(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for line in description.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let timeRange = Range(match.range(at: 1), in: line),
                  let titleRange = Range(match.range(at: 2), in: line) else { continue }
            let seconds = parseTimestamp(String(line[timeRange]))
            let title = String(line[titleRange])
            guard let seconds, !title.isEmpty else { continue }
            if let duration, seconds >= duration { continue }
            if let last = result.last, seconds <= last.startSeconds { continue }
            result.append(Chapter(title: title, startSeconds: seconds))
        }
        guard result.count >= 3, result.first?.startSeconds == 0 else { return [] }
        return result
    }

    public static func parseTimestamp(_ text: String) -> Double? {
        let parts = text.split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return Double(parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 })
    }

    /// Index of the chapter containing `time`.
    public static func index(of time: Double, in chapters: [Chapter]) -> Int? {
        guard !chapters.isEmpty else { return nil }
        var found: Int?
        for (i, chapter) in chapters.enumerated() where chapter.startSeconds <= time + 0.01 {
            found = i
        }
        return found
    }
}

/// How long cached data stays fresh. Feeds refresh on timers, never on every navigation.
public enum RefreshPolicy {
    public enum Category: String, Sendable, CaseIterable {
        case home
        case subscriptions
        case videoInfo
        case channel
        case library
        case search
    }

    public static func ttl(_ category: Category) -> TimeInterval {
        switch category {
        case .home, .subscriptions: return 15 * 60
        case .videoInfo: return 5 * 60
        case .channel: return 60 * 60
        case .library: return 15 * 60
        case .search: return 10 * 60
        }
    }

    public static func isFresh(fetchedAt: Date, category: Category, now: Date = Date()) -> Bool {
        now.timeIntervalSince(fetchedAt) < ttl(category)
    }
}

/// Small in-memory cache with per-entry expiry.
public final class TTLCache<Key: Hashable, Value> {
    private var storage: [Key: (value: Value, expires: Date)] = [:]
    private let lock = NSLock()

    public init() {}

    public func value(for key: Key, now: Date = Date()) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = storage[key] else { return nil }
        if entry.expires <= now {
            storage[key] = nil
            return nil
        }
        return entry.value
    }

    public func set(_ value: Value, for key: Key, ttl: TimeInterval, now: Date = Date()) {
        lock.lock()
        storage[key] = (value, now.addingTimeInterval(ttl))
        lock.unlock()
    }

    public func remove(_ key: Key) {
        lock.lock()
        storage[key] = nil
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}
