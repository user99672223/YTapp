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
        // Only answers to requests made with the signed-in session may rotate its cookies
        // (validating newly pasted cookies must not touch the stored ones), and only while that
        // session is still the stored one.
        var sessionGeneration: Int?
        for pair in headers where pair.count == 2 {
            let name = pair[0]
            var value = pair[1]
            let lower = name.lowercased()
            if lower == "host" || lower == "content-length" || lower == "connection" { continue }
            if lower == "cookie", isYouTube {
                let substituted = cookies.substitute(value)
                value = substituted.header
                sessionGeneration = substituted.generation
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
        let carriedGeneration = sessionGeneration
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
            if let generation = carriedGeneration, http.url?.host?.lowercased().hasSuffix("youtube.com") ?? isYouTube {
                self?.cookies.absorb(responseHeaders: headerMap, url: http.url ?? requestURL, generation: generation)
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
    /// Every header this session has had since it was stored. A YouTube.js session keeps sending
    /// the header it was created with, so all of them are recognised and upgraded.
    private var known: Set<String> = []
    /// Headers YouTube.js sessions were created with (`sessionHeader()`), newest last. They are
    /// never dropped from `known` by its cap, since a session sends its header for as long as it lives.
    private var sessionHeaders: [String] = []
    private var jar = CookieJar(header: "")
    private var saveWork: DispatchWorkItem?
    /// A rotated header of the current generation not yet written to the Keychain.
    private var pendingSave: String?
    private var generation = 0
    private let keychain: KeychainStore
    /// Serialises Keychain writes, so a delayed rotation can't overwrite a newer `replace`/`clear`.
    /// Always taken before `lock`, never while holding it.
    private let saveLock = NSLock()

    init(keychain: KeychainStore) {
        self.keychain = keychain
        if let stored = keychain.loadCookie(), !stored.isEmpty {
            known = [stored]
            jar = CookieJar(header: stored)
        }
    }

    var header: String {
        lock.lock()
        defer { lock.unlock() }
        return jar.header
    }

    var hasCookies: Bool { !header.isEmpty }

    /// The header to create a YouTube.js session with. That session sends exactly this header
    /// on every request, so it stays recognised (and upgraded) however often cookies rotate.
    func sessionHeader() -> String {
        lock.lock()
        defer { lock.unlock() }
        let header = jar.header
        guard !header.isEmpty else { return header }
        known.insert(header)
        sessionHeaders.removeAll { $0 == header }
        sessionHeaders.append(header)
        // Only the latest session is used; a few more cover sessions created concurrently.
        if sessionHeaders.count > 8 { sessionHeaders.removeFirst(sessionHeaders.count - 8) }
        return header
    }

    /// Replaces the stored session (after setup or re-entry). Returns false when the Keychain
    /// didn't take it: the sign-in then only lasts until the app quits.
    @discardableResult
    func replace(with header: String) -> Bool {
        saveLock.lock()
        defer { saveLock.unlock() }
        lock.lock()
        known = header.isEmpty ? [] : [header]
        sessionHeaders = []
        jar = CookieJar(header: header)
        generation += 1
        pendingSave = nil
        saveWork?.cancel()
        saveWork = nil
        lock.unlock()
        return keychain.saveCookie(header)
    }

    func clear() {
        saveLock.lock()
        defer { saveLock.unlock() }
        lock.lock()
        known = []
        sessionHeaders = []
        jar = CookieJar(header: "")
        generation += 1
        pendingSave = nil
        saveWork?.cancel()
        saveWork = nil
        lock.unlock()
        keychain.deleteCookie()
    }

    /// Writes a pending rotation to the Keychain now instead of after the debounce. Called when
    /// the app leaves the foreground: tvOS may terminate it there before the timer fires.
    func flush() {
        saveLock.lock()
        defer { saveLock.unlock() }
        lock.lock()
        let header = pendingSave
        pendingSave = nil
        saveWork?.cancel()
        saveWork = nil
        lock.unlock()
        if let header { keychain.saveCookie(header) }
    }

    /// If `requestCookie` is a header of the stored session, send the freshest version instead
    /// and return the session's generation (pass it to `absorb`). Other cookie headers (e.g.
    /// validation of newly pasted cookies) pass through untouched, with no generation.
    func substitute(_ requestCookie: String) -> (header: String, generation: Int?) {
        lock.lock()
        defer { lock.unlock() }
        guard known.contains(requestCookie) else { return (requestCookie, nil) }
        return (jar.header, generation)
    }

    /// Folds cookies YouTube rotated into the stored session. `generation` is what `substitute`
    /// returned when the request was sent: if the cookies were replaced or cleared since (another
    /// account), the answer belongs to the old session and is ignored.
    func absorb(responseHeaders: [String: String], url: URL, generation: Int) {
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: responseHeaders, for: url)
        guard !cookies.isEmpty else { return }
        let updates = cookies.map {
            CookieJar.Update(name: $0.name, value: $0.value, domain: $0.domain, expires: $0.expiresDate)
        }
        lock.lock()
        guard !known.isEmpty, generation == self.generation else {
            lock.unlock()
            return
        }
        let before = jar.header
        let changed = jar.apply(updates)
        let header = jar.header
        if changed {
            // Rotations are rare (minutes apart); the cap only guards very long-running sessions.
            // The headers live sessions send are kept, or their requests would go out stale.
            if known.count > 512 {
                var kept = Set(sessionHeaders)
                kept.insert(before)
                known = kept
            }
            known.insert(header)
            pendingSave = header
        }
        lock.unlock()
        guard changed else { return }
        scheduleSave()
    }

    /// Writes `pendingSave` 5 s after the last rotation (they come in bursts).
    private func scheduleSave() {
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        lock.lock()
        saveWork?.cancel()
        saveWork = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: work)
    }
}
