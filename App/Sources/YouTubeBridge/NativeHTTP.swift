import Foundation
import Core

/// URLSession-backed HTTP for the JS `fetch` polyfill. Cookies are handled explicitly: URLSession
/// never stores or sends cookies by itself; YouTube.js sets the `Cookie` header, and rotated
/// youtube.com cookies are folded back into the stored session (see `CookieStore`).
final class NativeHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    struct Response {
        let status: Int
        let finalURL: String
        let headers: [String: String]
        let body: Data

        var isTextual: Bool {
            let type = (headers.first { $0.key.lowercased() == "content-type" }?.value ?? "").lowercased()
            return type.contains("json") || type.contains("javascript") || type.hasPrefix("text/") ||
                type.contains("xml") || type.contains("html")
        }
    }

    private(set) var session: URLSession!
    let cookies: CookieStore
    private let noRedirectTasks = NSMutableSet()
    private let lock = NSLock()

    init(cookies: CookieStore) {
        self.cookies = cookies
        super.init()
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Starts a request; `completion` runs on a URLSession queue.
    func send(url: String, method: String, headers: [[String]], body: Data?, followRedirects: Bool,
              completion: @escaping (Result<Response, Error>) -> Void) -> URLSessionTask? {
        guard let requestURL = URL(string: url), let scheme = requestURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        let isYouTube = requestURL.host?.lowercased().hasSuffix("youtube.com") ?? false
        for pair in headers where pair.count == 2 {
            let name = pair[0]
            var value = pair[1]
            let lower = name.lowercased()
            if lower == "host" || lower == "content-length" || lower == "connection" { continue }
            if lower == "cookie", isYouTube { value = cookies.substitute(value) }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body, method != "GET", method != "HEAD" { request.httpBody = body }
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            var headerMap: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String { headerMap[k] = v }
            }
            if isYouTube || (http.url?.host?.lowercased().hasSuffix("youtube.com") ?? false) {
                self?.cookies.absorb(responseHeaders: headerMap, url: http.url ?? requestURL)
            }
            completion(.success(Response(status: http.statusCode, finalURL: http.url?.absoluteString ?? url,
                                         headers: headerMap, body: data ?? Data())))
        }
        if !followRedirects {
            lock.lock()
            noRedirectTasks.add(task.taskIdentifier)
            lock.unlock()
        }
        task.resume()
        return task
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        let blocked = noRedirectTasks.contains(task.taskIdentifier)
        lock.unlock()
        guard !blocked else {
            completionHandler(nil)
            return
        }
        // Keep the Cookie header only while staying on youtube.com.
        var next = request
        if !(request.url?.host?.lowercased().hasSuffix("youtube.com") ?? false) {
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        noRedirectTasks.remove(task.taskIdentifier)
        lock.unlock()
    }
}

/// The signed-in cookie header. Starts from the Keychain; rotated values YouTube sends via
/// `Set-Cookie` update it and are written back (debounced) so the session stays alive.
final class CookieStore: @unchecked Sendable {
    private let lock = NSLock()
    private var original: String = ""
    private var jar = CookieJar(header: "")
    private var saveWork: DispatchWorkItem?
    private let keychain: KeychainStore

    init(keychain: KeychainStore) {
        self.keychain = keychain
        if let stored = keychain.loadCookie() {
            original = stored
            jar = CookieJar(header: stored)
        }
    }

    var header: String {
        lock.lock()
        defer { lock.unlock() }
        return jar.header
    }

    var hasCookies: Bool { !header.isEmpty }

    /// Replaces the stored session (after setup or re-entry).
    func replace(with header: String) {
        lock.lock()
        original = header
        jar = CookieJar(header: header)
        lock.unlock()
        keychain.saveCookie(header)
    }

    func clear() {
        lock.lock()
        original = ""
        jar = CookieJar(header: "")
        lock.unlock()
        keychain.deleteCookie()
    }

    /// If `requestCookie` is the session cookie YouTube.js was created with, send the freshest
    /// version instead. Other cookie headers (e.g. validation of new cookies) pass through.
    func substitute(_ requestCookie: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !original.isEmpty, requestCookie == original || requestCookie == jar.header else { return requestCookie }
        return jar.header
    }

    func absorb(responseHeaders: [String: String], url: URL) {
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: responseHeaders, for: url)
        guard !cookies.isEmpty else { return }
        let updates = cookies.map {
            CookieJar.Update(name: $0.name, value: $0.value, domain: $0.domain, expires: $0.expiresDate)
        }
        lock.lock()
        guard !original.isEmpty else {
            lock.unlock()
            return
        }
        let changed = jar.apply(updates)
        let header = jar.header
        lock.unlock()
        guard changed else { return }
        scheduleSave(header)
    }

    private func scheduleSave(_ header: String) {
        lock.lock()
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.keychain.saveCookie(header) }
        saveWork = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: work)
    }
}
