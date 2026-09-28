import Foundation

public enum CookieParseError: Error, Equatable, LocalizedError {
    case empty
    case unrecognized
    case noYouTubeCookies
    case missingAuthCookies

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "The box was empty. Paste your YouTube cookies and try again."
        case .unrecognized:
            return "That doesn't look like cookies. Paste the cookies.txt export (or the Cookie header) from youtube.com."
        case .noYouTubeCookies:
            return "No youtube.com cookies were found in what you pasted. Export the cookies while youtube.com is open."
        case .missingAuthCookies:
            return "These cookies are from a signed-out session (SAPISID/SID are missing). Sign in to YouTube in the private window first, then export again."
        }
    }
}

/// Normalizes pasted cookies (Netscape cookies.txt, JSON exports, or a raw `Cookie:` header)
/// into a single `name=value; ...` header string for youtube.com.
public enum CookieParser {
    public struct Cookie: Equatable, Sendable {
        public var name: String
        public var value: String
        public var domain: String?

        public init(name: String, value: String, domain: String? = nil) {
            self.name = name
            self.value = value
            self.domain = domain
        }
    }

    public static func parse(_ raw: String) throws -> String {
        let cookies = try parseCookies(raw)
        return header(from: cookies)
    }

    public static func parseCookies(_ raw: String) throws -> [Cookie] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CookieParseError.empty }

        var cookies: [Cookie]
        if text.hasPrefix("[") || text.hasPrefix("{") {
            cookies = try parseJSON(text)
        } else if text.contains("\t") {
            cookies = parseNetscape(text)
        } else {
            cookies = parseHeader(text)
        }
        if cookies.isEmpty { throw CookieParseError.unrecognized }

        // Keep youtube.com cookies (or domain-less ones from a header paste).
        let relevant = cookies.filter { cookie in
            guard let domain = cookie.domain?.lowercased() else { return true }
            let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            return d == "youtube.com" || d.hasSuffix(".youtube.com")
        }
        if relevant.isEmpty { throw CookieParseError.noYouTubeCookies }

        // Deduplicate by name, preferring the most specific youtube.com domain.
        var byName: [String: Cookie] = [:]
        var order: [String] = []
        for cookie in relevant where !cookie.name.isEmpty {
            if byName[cookie.name] == nil { order.append(cookie.name) }
            if let existing = byName[cookie.name], existing.domain == ".youtube.com" || existing.domain == "youtube.com" {
                if cookie.domain == "www.youtube.com" { byName[cookie.name] = cookie }
            } else if byName[cookie.name] == nil {
                byName[cookie.name] = cookie
            }
        }
        var result = order.compactMap { byName[$0] }

        // YouTube.js signs requests with SAPISID; some exports only carry __Secure-3PAPISID
        // (same value).
        if !result.contains(where: { $0.name == "SAPISID" }),
           let secure = result.first(where: { $0.name == "__Secure-3PAPISID" }) {
            result.append(Cookie(name: "SAPISID", value: secure.value, domain: secure.domain))
        }
        let names = Set(result.map(\.name))
        let hasSession = names.contains("SID") || names.contains("__Secure-1PSID") || names.contains("__Secure-3PSID")
        guard names.contains("SAPISID"), hasSession else { throw CookieParseError.missingAuthCookies }
        return result
    }

    public static func header(from cookies: [Cookie]) -> String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: - Formats

    static func parseNetscape(_ text: String) -> [Cookie] {
        var out: [Cookie] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#HttpOnly_") {
                line = String(line.dropFirst("#HttpOnly_".count))
            } else if line.hasPrefix("#") || line.isEmpty {
                continue
            }
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 7 else { continue }
            let value = fields[6...].joined(separator: "\t").trimmingCharacters(in: .whitespaces)
            out.append(Cookie(name: fields[5].trimmingCharacters(in: .whitespaces), value: value, domain: fields[0]))
        }
        return out
    }

    static func parseHeader(_ text: String) -> [Cookie] {
        var body = text
        if body.lowercased().hasPrefix("cookie:") { body = String(body.dropFirst(7)) }
        let parts = body.split(whereSeparator: { $0 == ";" || $0.isNewline })
        var out: [Cookie] = []
        for part in parts {
            let item = part.trimmingCharacters(in: .whitespaces)
            guard let eq = item.firstIndex(of: "=") else { continue }
            let name = String(item[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(item[item.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { continue }
            out.append(Cookie(name: name, value: value))
        }
        return out
    }

    static func parseJSON(_ text: String) throws -> [Cookie] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            throw CookieParseError.unrecognized
        }
        var list: [Any] = []
        if let array = json as? [Any] {
            list = array
        } else if let object = json as? [String: Any] {
            if let cookies = object["cookies"] as? [Any] {
                list = cookies
            } else {
                // { "name": "value", ... }
                return object.compactMap { key, value in
                    (value as? String).map { Cookie(name: key, value: $0) }
                }.sorted { $0.name < $1.name }
            }
        }
        return list.compactMap { entry in
            guard let dict = entry as? [String: Any],
                  let name = dict["name"] as? String,
                  let value = dict["value"] as? String else { return nil }
            return Cookie(name: name, value: value, domain: dict["domain"] as? String)
        }
    }
}
