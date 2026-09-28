import Foundation
import JavaScriptCore
import CryptoKit
import Security
import Core

/// Hosts YouTube.js (App/Resources/js/youtubei.bundle.js) in a JavaScriptCore context and
/// provides the native functions its polyfills expect (`globalThis.__native`, see
/// js/src/polyfills/native.js). All JS work happens on one serial queue.
final class JSRuntime: BridgeTransport, @unchecked Sendable {
    let bundleURL: URL
    let logs: LogBuffer
    private let http: NativeHTTP
    private let cache: FileCache
    private let queue = DispatchQueue(label: "tube.javascript", qos: .userInitiated)
    private var context: JSContext?
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timers: [Int: DispatchWorkItem] = [:]
    private var fetchTasks: [Int: URLSessionTask] = [:]
    private var nextCallId = 0

    init(bundleURL: URL, http: NativeHTTP, cache: FileCache, logs: LogBuffer) {
        self.bundleURL = bundleURL
        self.http = http
        self.cache = cache
        self.logs = logs
    }

    // MARK: - Loading

    /// Evaluates the bundle and returns its version info.
    func load() async throws -> BundleInfo {
        let code: String
        do {
            code = try String(contentsOf: bundleURL, encoding: .utf8)
        } catch {
            throw BridgeError(kind: .bridge, message: "Couldn't read the YouTube bundle: \(error.localizedDescription)")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BundleInfo, Error>) in
            queue.async {
                guard let context = JSContext() else {
                    continuation.resume(throwing: BridgeError(kind: .bridge, message: "JavaScriptCore is not available."))
                    return
                }
                context.name = "Tube YouTube bridge"
                var lastException: String?
                context.exceptionHandler = { [weak self] _, exception in
                    let text = exception?.toString() ?? "unknown"
                    let stack = exception?.objectForKeyedSubscript("stack")?.toString() ?? ""
                    lastException = text
                    self?.logs.append(.error, "JS exception: \(text) \(stack)")
                }
                self.context = context
                self.installNatives(in: context)
                context.evaluateScript(code, withSourceURL: self.bundleURL)
                guard let bridge = context.objectForKeyedSubscript("TubeBridge"), bridge.isObject,
                      let infoValue = bridge.objectForKeyedSubscript("bundleInfo"), infoValue.isObject else {
                    continuation.resume(throwing: BridgeError(kind: .bridge, message: "The YouTube bundle failed to start: \(lastException ?? "TubeBridge missing")."))
                    return
                }
                let info = BundleInfo(
                    bundleVersion: infoValue.objectForKeyedSubscript("bundleVersion")?.toString() ?? "?",
                    youtubeiVersion: infoValue.objectForKeyedSubscript("youtubeiVersion")?.toString() ?? "?",
                    bgutilsVersion: infoValue.objectForKeyedSubscript("bgutilsVersion")?.toString(),
                    protocol: Int(infoValue.objectForKeyedSubscript("protocol")?.toInt32() ?? 0)
                )
                continuation.resume(returning: info)
            }
        }
    }

    /// Stops everything (used when the bundle is replaced).
    func shutdown() {
        queue.sync {
            for (_, timer) in timers { timer.cancel() }
            timers.removeAll()
            for (_, task) in fetchTasks { task.cancel() }
            fetchTasks.removeAll()
            let error = BridgeError(kind: .bridge, message: "The YouTube bridge restarted.")
            for (_, continuation) in pending { continuation.resume(throwing: error) }
            pending.removeAll()
            context = nil
        }
    }

    // MARK: - BridgeTransport

    func call(method: String, argsJSON: String) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async {
                guard let context = self.context,
                      let bridge = context.objectForKeyedSubscript("TubeBridge"), bridge.isObject else {
                    continuation.resume(throwing: BridgeError(kind: .bridge, message: "The YouTube bundle isn't loaded."))
                    return
                }
                self.nextCallId += 1
                let id = self.nextCallId
                self.pending[id] = continuation
                let timeout: TimeInterval = method == "init" ? 300 : 150
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, let waiting = self.pending.removeValue(forKey: id) else { return }
                    self.logs.append(.error, "bridge \(method) timed out after \(Int(timeout)) s")
                    waiting.resume(throwing: BridgeError(kind: .timeout, message: "YouTube took too long to answer (\(method))."))
                }
                bridge.invokeMethod("call", withArguments: [id, method, argsJSON])
            }
        }
    }

    // MARK: - Natives

    private func installNatives(in context: JSContext) {
        let native = JSValue(newObjectIn: context)!

        let log: @convention(block) (String, String) -> Void = { [weak self] level, message in
            self?.logs.append(LogBuffer.Level(js: level), message)
        }
        let reply: @convention(block) (JSValue, JSValue, JSValue) -> Void = { [weak self] idValue, errorValue, resultValue in
            guard let self else { return }
            let id = Int(idValue.toInt32())
            guard let continuation = self.pending.removeValue(forKey: id) else { return }
            if !errorValue.isNull, !errorValue.isUndefined, let json = errorValue.toString() {
                let error = (try? JSONDecoder().decode(BridgeError.self, from: Data(json.utf8)))
                    ?? BridgeError(kind: .unknown, message: json)
                continuation.resume(throwing: error)
            } else {
                let json = (resultValue.isNull || resultValue.isUndefined) ? "null" : (resultValue.toString() ?? "null")
                continuation.resume(returning: Data(json.utf8))
            }
        }
        let setTimer: @convention(block) (JSValue, JSValue) -> Void = { [weak self] idValue, msValue in
            guard let self else { return }
            let id = Int(idValue.toInt32())
            let ms = max(0, msValue.toDouble().isFinite ? msValue.toDouble() : 0)
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.timers.removeValue(forKey: id) != nil else { return }
                self.invokeGlobal("__tubeTimerFire", [id])
            }
            self.timers[id]?.cancel()
            self.timers[id] = item
            self.queue.asyncAfter(deadline: .now() + ms / 1000, execute: item)
        }
        let clearTimer: @convention(block) (JSValue) -> Void = { [weak self] idValue in
            let id = Int(idValue.toInt32())
            self?.timers.removeValue(forKey: id)?.cancel()
        }
        let now: @convention(block) () -> Double = {
            ProcessInfo.processInfo.systemUptime * 1000
        }
        let randomBytes: @convention(block) (JSValue) -> JSValue = { [weak self] countValue in
            guard let self else { return JSValue(undefinedIn: JSContext.current()) }
            let count = max(0, Int(countValue.toInt32()))
            var data = Data(count: count)
            if count > 0 {
                let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
                if status != errSecSuccess {
                    data = Data((0..<count).map { _ in UInt8.random(in: 0...255) })
                }
            }
            return self.makeBytes(data)
        }
        let utf8Encode: @convention(block) (String) -> JSValue = { [weak self] text in
            guard let self else { return JSValue(undefinedIn: JSContext.current()) }
            return self.makeBytes(Data(text.utf8))
        }
        let utf8Decode: @convention(block) (JSValue) -> String = { [weak self] value in
            guard let data = self?.bytes(from: value) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        let sha1Hex: @convention(block) (String) -> String = { text in
            Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let cacheGet: @convention(block) (String) -> JSValue = { [weak self] key in
            guard let self, let data = self.cache.get(key) else { return JSValue(nullIn: JSContext.current()) }
            return self.makeBytes(data)
        }
        let cacheSet: @convention(block) (String, JSValue) -> Void = { [weak self] key, value in
            guard let self, let data = self.bytes(from: value) else { return }
            self.cache.set(key, data)
        }
        let cacheRemove: @convention(block) (String) -> Void = { [weak self] key in
            self?.cache.remove(key)
        }
        let fetch: @convention(block) (JSValue, JSValue, JSValue, JSValue, JSValue, JSValue) -> Void = { [weak self] idValue, urlValue, methodValue, headersValue, bodyValue, redirectValue in
            guard let self else { return }
            let id = Int(idValue.toInt32())
            let url = urlValue.toString() ?? ""
            let method = methodValue.toString() ?? "GET"
            let headerJSON = headersValue.toString() ?? "[]"
            let pairs = (try? JSONSerialization.jsonObject(with: Data(headerJSON.utf8))) as? [[String]] ?? []
            var body: Data?
            if bodyValue.isString {
                body = Data((bodyValue.toString() ?? "").utf8)
            } else if !bodyValue.isNull, !bodyValue.isUndefined {
                body = self.bytes(from: bodyValue)
            }
            let followRedirects = redirectValue.toString() != "manual"
            let task = self.http.send(url: url, method: method, headers: pairs, body: body, followRedirects: followRedirects) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard self.fetchTasks.removeValue(forKey: id) != nil else { return }
                    self.deliverFetch(id: id, requestURL: url, result: result)
                }
            }
            if let task { self.fetchTasks[id] = task }
            else { self.invokeGlobal("__tubeFetchDone", [id, "Invalid URL: \(url)", 0, "", url, "[]", NSNull()]) }
        }
        let fetchCancel: @convention(block) (JSValue) -> Void = { [weak self] idValue in
            guard let self else { return }
            let id = Int(idValue.toInt32())
            self.fetchTasks.removeValue(forKey: id)?.cancel()
        }

        // Blocks must be bridged while their static type is still the block type.
        let natives: [(String, AnyObject)] = [
            ("log", unsafeBitCast(log, to: AnyObject.self)),
            ("reply", unsafeBitCast(reply, to: AnyObject.self)),
            ("setTimer", unsafeBitCast(setTimer, to: AnyObject.self)),
            ("clearTimer", unsafeBitCast(clearTimer, to: AnyObject.self)),
            ("now", unsafeBitCast(now, to: AnyObject.self)),
            ("randomBytes", unsafeBitCast(randomBytes, to: AnyObject.self)),
            ("utf8Encode", unsafeBitCast(utf8Encode, to: AnyObject.self)),
            ("utf8Decode", unsafeBitCast(utf8Decode, to: AnyObject.self)),
            ("sha1Hex", unsafeBitCast(sha1Hex, to: AnyObject.self)),
            ("cacheGet", unsafeBitCast(cacheGet, to: AnyObject.self)),
            ("cacheSet", unsafeBitCast(cacheSet, to: AnyObject.self)),
            ("cacheRemove", unsafeBitCast(cacheRemove, to: AnyObject.self)),
            ("fetch", unsafeBitCast(fetch, to: AnyObject.self)),
            ("fetchCancel", unsafeBitCast(fetchCancel, to: AnyObject.self))
        ]
        for (name, block) in natives {
            native.setObject(block, forKeyedSubscript: name as NSString)
        }
        context.setObject(native, forKeyedSubscript: "__native" as NSString)
    }

    private func deliverFetch(id: Int, requestURL: String, result: Result<NativeHTTP.Response, Error>) {
        switch result {
        case .failure(let error):
            invokeGlobal("__tubeFetchDone", [id, error.localizedDescription, 0, "", requestURL, "[]", NSNull()])
        case .success(let response):
            let headerPairs = response.headers.map { [$0.key, $0.value] }
            let headersJSON = (try? JSONSerialization.data(withJSONObject: headerPairs)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            let body: Any
            if response.isTextual, let text = String(data: response.body, encoding: .utf8) {
                body = text
            } else {
                body = makeBytes(response.body)
            }
            invokeGlobal("__tubeFetchDone", [id, NSNull(), response.status, HTTPURLResponse.localizedString(forStatusCode: response.status), response.finalURL, headersJSON, body])
        }
    }

    private func invokeGlobal(_ name: String, _ arguments: [Any]) {
        guard let context, let function = context.objectForKeyedSubscript(name), !function.isUndefined else { return }
        function.call(withArguments: arguments)
    }

    // MARK: - Typed arrays

    private func makeBytes(_ data: Data) -> JSValue {
        guard let context else { return JSValue(nullIn: JSContext.current()) }
        let count = data.count
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 16)
        if count > 0 {
            data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: count)
        }
        var exception: JSValueRef?
        let object = JSObjectMakeTypedArrayWithBytesNoCopy(
            context.jsGlobalContextRef, kJSTypedArrayTypeUint8Array, pointer, count,
            { bytes, _ in bytes?.deallocate() }, nil, &exception)
        guard let object, exception == nil else {
            pointer.deallocate()
            return JSValue(nullIn: context)
        }
        return JSValue(jsValueRef: object, in: context)
    }

    private func bytes(from value: JSValue) -> Data? {
        guard let context, let ref = value.jsValueRef else { return nil }
        let ctx = context.jsGlobalContextRef
        var exception: JSValueRef?
        let type = JSValueGetTypedArrayType(ctx, ref, &exception)
        if type == kJSTypedArrayTypeNone || type == kJSTypedArrayTypeArrayBuffer { return nil }
        guard let object = JSValueToObject(ctx, ref, &exception) else { return nil }
        let length = JSObjectGetTypedArrayByteLength(ctx, object, &exception)
        guard length > 0 else { return Data() }
        let offset = JSObjectGetTypedArrayByteOffset(ctx, object, &exception)
        guard let base = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception) else { return nil }
        return Data(bytes: base.advanced(by: offset), count: length)
    }
}

/// Files for YouTube.js' ICache (deciphered player, session data) in Caches/youtubei.
final class FileCache: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? String($0) : "_" }.joined()
        return directory.appendingPathComponent(safe.isEmpty ? "_" : safe)
    }

    func get(_ key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try? Data(contentsOf: url(for: key))
    }

    func set(_ key: String, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: key), options: .atomic)
    }

    func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(for: key))
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var totalBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

/// Ring buffer of recent log lines for the debug screen.
final class LogBuffer: @unchecked Sendable {
    enum Level: String {
        case debug, info, warn, error

        init(js: String) {
            switch js {
            case "error": self = .error
            case "warn": self = .warn
            case "info", "log": self = .info
            default: self = .debug
            }
        }
    }

    struct Line: Identifiable {
        let id: Int
        let date: Date
        let level: Level
        let text: String
    }

    private var lines: [Line] = []
    private var counter = 0
    private let lock = NSLock()
    private let capacity = 300

    func append(_ level: Level, _ text: String) {
        lock.lock()
        counter += 1
        lines.append(Line(id: counter, date: Date(), level: level, text: String(text.prefix(2000))))
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        lock.unlock()
        #if DEBUG
        print("[\(level.rawValue)] \(text)")
        #endif
    }

    var snapshot: [Line] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
