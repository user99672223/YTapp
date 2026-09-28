import Foundation

/// Minimal HTTP/1.1 request parsing for the on-device setup page (NWListener on port 8765).
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public var bodyText: String { String(decoding: body, as: UTF8.self) }

    /// Form fields for `application/x-www-form-urlencoded` bodies (or the raw body as `cookies`
    /// for text/plain posts).
    public var formFields: [String: String] {
        let type = headers["content-type"]?.lowercased() ?? ""
        if type.contains("application/x-www-form-urlencoded") {
            return FormURLEncoded.decode(bodyText)
        }
        return ["cookies": bodyText]
    }
}

public enum HTTPParseResult: Equatable, Sendable {
    case incomplete
    case complete(HTTPRequest, consumed: Int)
    case invalid(String)
}

public enum HTTPRequestParser {
    public static let maxHeaderBytes = 32 * 1024
    public static let maxBodyBytes = 2 * 1024 * 1024

    public static func parse(_ data: Data) -> HTTPParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else {
            return data.count > maxHeaderBytes ? .invalid("Request headers too large") : .incomplete
        }
        let headerData = data[data.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return .invalid("Headers are not UTF-8") }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid("Empty request") }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return .invalid("Malformed request line") }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .invalid("Chunked uploads are not supported")
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid("Bad Content-Length") }
        guard length <= maxBodyBytes else { return .invalid("Body too large") }
        let bodyStart = headerEnd.upperBound
        let available = data.endIndex - bodyStart
        guard available >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]

        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            query = FormURLEncoded.decode(String(target[target.index(after: q)...]))
        }
        let request = HTTPRequest(method: method, path: path, query: query, headers: headers, body: Data(body))
        return .complete(request, consumed: (bodyStart - data.startIndex) + length)
    }
}

public enum FormURLEncoded {
    public static func decode(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = unescape(String(parts[0]))
            let value = parts.count > 1 ? unescape(String(parts[1])) : ""
            if out[key] == nil { out[key] = value }
        }
        return out
    }

    public static func unescape(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var reason: String
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, reason: String, contentType: String, body: Data) {
        self.status = status
        self.reason = reason
        self.headers = [("Content-Type", contentType), ("Cache-Control", "no-store"), ("Connection", "close")]
        self.body = body
    }

    public static func html(_ html: String, status: Int = 200, reason: String = "OK") -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, contentType: "text/html; charset=utf-8", body: Data(html.utf8))
    }

    public static func json(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, reason: status == 200 ? "OK" : "Error", contentType: "application/json", body: data)
    }

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    public static func == (lhs: HTTPResponse, rhs: HTTPResponse) -> Bool {
        lhs.status == rhs.status && lhs.body == rhs.body && lhs.headers.map { $0.0 + $0.1 } == rhs.headers.map { $0.0 + $0.1 }
    }
}
