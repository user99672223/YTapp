import Foundation

/// Keeps the stored cookie header fresh: when YouTube rotates a cookie we already hold
/// (e.g. `__Secure-3PSIDTS`, `SIDCC`) via `Set-Cookie`, the new value replaces the old one.
/// New cookies and deletions are ignored so a signed-out response can never erase the session.
public struct CookieJar: Equatable, Sendable {
    public struct Update: Equatable, Sendable {
        public var name: String
        public var value: String
        public var domain: String?
        public var expires: Date?
        public var maxAge: Int?

        public init(name: String, value: String, domain: String? = nil, expires: Date? = nil, maxAge: Int? = nil) {
            self.name = name
            self.value = value
            self.domain = domain
            self.expires = expires
            self.maxAge = maxAge
        }
    }

    public private(set) var cookies: [(name: String, value: String)]

    public init(header: String) {
        cookies = header.split(separator: ";").compactMap { part in
            let item = part.trimmingCharacters(in: .whitespaces)
            guard let eq = item.firstIndex(of: "=") else { return nil }
            return (String(item[..<eq]), String(item[item.index(after: eq)...]))
        }
    }

    public var header: String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    public func value(_ name: String) -> String? {
        cookies.first(where: { $0.name == name })?.value
    }

    /// Applies updates; returns true when something changed.
    @discardableResult
    public mutating func apply(_ updates: [Update], now: Date = Date()) -> Bool {
        var changed = false
        for update in updates {
            if let domain = update.domain?.lowercased() {
                let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
                guard d == "youtube.com" || d.hasSuffix(".youtube.com") else { continue }
            }
            guard !update.value.isEmpty else { continue }
            if let maxAge = update.maxAge, maxAge <= 0 { continue }
            if let expires = update.expires, expires <= now { continue }
            guard let index = cookies.firstIndex(where: { $0.name == update.name }) else { continue }
            if cookies[index].value != update.value {
                cookies[index].value = update.value
                changed = true
            }
        }
        return changed
    }

    /// Parses one `Set-Cookie` header value.
    public static func parseSetCookie(_ line: String) -> Update? {
        let parts = line.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, let eq = first.firstIndex(of: "=") else { return nil }
        var update = Update(name: String(first[..<eq]), value: String(first[first.index(after: eq)...]))
        for attribute in parts.dropFirst() {
            let kv = attribute.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            // Empty pieces ("a=b; ; Secure", a trailing "; ") and nameless ones ("=x") are skipped.
            guard let key = kv.first, !key.isEmpty else { continue }
            let value: String? = kv.count > 1 && !kv[1].isEmpty ? kv[1] : nil
            switch key.lowercased() {
            case "domain": update.domain = value
            case "max-age": update.maxAge = value.flatMap { Int($0) }
            case "expires": update.expires = value.flatMap { httpDate($0) }
            default: break
            }
        }
        return update
    }

    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    public static func == (lhs: CookieJar, rhs: CookieJar) -> Bool { lhs.header == rhs.header }
}
