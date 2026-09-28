import Foundation
import SwiftUI
import Core

/// App-wide state: the JS runtime + YouTube session, settings, account and error banners.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case launching
        case needsSetup
        case connecting(String)
        case ready
        case failed(BridgeError)
    }

    @Published private(set) var phase: Phase = .launching
    @Published private(set) var account: AccountInfo?
    @Published private(set) var session: SessionSummary?
    @Published private(set) var bundleInfo: BundleInfo?
    @Published var authProblem: String?
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            store.saveSettings(settings)
            if settings.streamClient != oldValue.streamClient || settings.poTokenMode != oldValue.poTokenMode {
                let client = settings.streamClient
                let mode = settings.poTokenMode
                Task { try? await self.service?.setClient(client, poTokenMode: mode) }
            }
        }
    }

    let store: Store
    let keychain: KeychainStore
    let cookies: CookieStore
    let http: NativeHTTP
    let logs: LogBuffer
    let bundles: BundleManager
    let fileCache: FileCache
    /// Video info is reused for 5 minutes (RefreshPolicy.videoInfo) instead of refetching.
    let videoInfoCache = TTLCache<String, VideoDetails>()
    private(set) var runtime: JSRuntime?
    private(set) var service: YouTubeService?
    private var authFailures = 0
    private var recreating: Task<Void, Never>?

    init() {
        let logs = LogBuffer()
        let store = Store(logs: logs)
        let keychain = KeychainStore()
        let cookies = CookieStore(keychain: keychain)
        self.logs = logs
        self.store = store
        self.keychain = keychain
        self.cookies = cookies
        bundles = BundleManager(logs: logs)
        http = NativeHTTP(cookies: cookies)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        fileCache = FileCache(directory: caches.appendingPathComponent("youtubei", isDirectory: true))
        settings = store.loadSettings()
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024,
                                   directory: caches.appendingPathComponent("images", isDirectory: true))
    }

    var isSignedIn: Bool { cookies.hasCookies }

    // MARK: - Lifecycle

    func start() async {
        phase = .launching
        do {
            try await loadRuntime()
        } catch {
            phase = .failed(BridgeError.wrap(error))
            return
        }
        guard cookies.hasCookies else {
            phase = .needsSetup
            return
        }
        await connect(showProgress: true)
    }

    private func loadRuntime() async throws {
        runtime?.shutdown()
        runtime = nil
        service = nil
        guard let url = bundles.activeURL else {
            throw BridgeError(kind: .bridge, message: "The YouTube bundle is missing from the app.")
        }
        let runtime = JSRuntime(bundleURL: url, http: http, cache: fileCache, logs: logs)
        do {
            bundleInfo = try await runtime.load()
        } catch {
            if bundles.hasDownloadedBundle {
                logs.append(.error, "Downloaded bundle failed to load (\(error.localizedDescription)); using the built-in one.")
                bundles.removeDownloadedBundle()
                return try await loadRuntime()
            }
            throw error
        }
        self.runtime = runtime
        service = YouTubeService(transport: runtime)
    }

    /// Creates (or recreates) the Innertube session with the stored cookies.
    func connect(showProgress: Bool) async {
        guard let service else {
            phase = .failed(BridgeError(kind: .bridge, message: "The YouTube bundle isn't running."))
            return
        }
        if showProgress { phase = .connecting("Connecting to YouTube…") }
        do {
            let options = SessionOptions(
                cookie: cookies.header,
                client: settings.streamClient,
                visitorData: settings.visitorData.isEmpty ? nil : settings.visitorData,
                poTokenMode: settings.poTokenMode
            )
            let summary = try await service.initialize(options)
            session = summary
            account = summary.account ?? account
            if settings.visitorData.isEmpty, let visitor = summary.visitorData, !visitor.isEmpty {
                settings.visitorData = visitor
            }
            if let accountError = summary.accountError {
                authProblem = "YouTube didn't accept your sign-in (\(accountError)). Re-enter your cookies in Settings."
            } else {
                authProblem = nil
            }
            if !summary.hasDecipher {
                logs.append(.warn, "The player script could not be analysed; streams may fail to unlock.")
            }
            authFailures = 0
            phase = .ready
        } catch {
            let wrapped = BridgeError.wrap(error)
            logs.append(.error, "Session creation failed: \(wrapped.message)")
            if showProgress || phase != .ready { phase = .failed(wrapped) }
        }
    }

    /// Recreates the session in the background (auth errors, client changes). Coalesced.
    func recreateSession() async {
        if let recreating {
            await recreating.value
            return
        }
        let task = Task { await self.connect(showProgress: false) }
        recreating = task
        await task.value
        recreating = nil
    }

    // MARK: - API access with auth recovery

    /// Runs a YouTube call. Repeated 401/403 answers recreate the session and retry once; if it
    /// still fails the user is told to re-enter cookies.
    func api<T>(_ operation: @escaping (YouTubeService) async throws -> T) async throws -> T {
        do {
            return try await apiWithRecovery(operation)
        } catch {
            let e = BridgeError.wrap(error)
            logs.append(.error, "api failed [\(e.kind.rawValue)\(e.status.map { " \($0)" } ?? "")]: \(e.message)\(e.detail.map { " | \($0.prefix(1500))" } ?? "")")
            throw error
        }
    }

    private func apiWithRecovery<T>(_ operation: @escaping (YouTubeService) async throws -> T) async throws -> T {
        guard let service else {
            throw BridgeError(kind: .noSession, message: "Not connected to YouTube yet.")
        }
        do {
            let value = try await operation(service)
            authFailures = 0
            return value
        } catch let error as BridgeError where error.kind == .noSession {
            await recreateSession()
            guard let fresh = self.service else { throw error }
            return try await operation(fresh)
        } catch let error as BridgeError where error.isAuthFailure {
            authFailures += 1
            guard authFailures >= 2 else { throw error }
            authFailures = 0
            await recreateSession()
            guard let fresh = self.service else { throw error }
            do {
                return try await operation(fresh)
            } catch let retry as BridgeError where retry.isAuthFailure {
                authProblem = "YouTube keeps rejecting your sign-in. Go to Settings → Re-enter cookies."
                throw retry
            }
        }
    }

    // MARK: - Account

    /// Validates pasted cookies with YouTube and, if they work, stores them and signs in.
    func submitCookies(_ raw: String) async throws -> AccountInfo {
        let header: String
        do {
            header = try CookieParser.parse(raw)
        } catch let error as CookieParseError {
            throw BridgeError(kind: .invalid, message: error.errorDescription ?? "Invalid cookies.")
        }
        guard let service else { throw BridgeError(kind: .bridge, message: "The YouTube bundle isn't running.") }
        let info = try await service.validateCookie(header)
        cookies.replace(with: header)
        account = info
        authProblem = nil
        fileCache.remove("innertube_session_data")
        // Answer the phone/computer right away; the session is created in the background.
        Task { await self.connect(showProgress: true) }
        return info
    }

    func signOut() {
        cookies.clear()
        account = nil
        session = nil
        store.clearFeedCache()
        fileCache.remove("innertube_session_data")
        phase = .needsSetup
    }

    /// Shows the setup screen again without deleting the working cookies until new ones validate.
    func beginCookieReentry() {
        phase = .needsSetup
    }

    func cancelCookieReentry() {
        guard cookies.hasCookies else { return }
        phase = service == nil ? .launching : .ready
        if service == nil { Task { await start() } }
    }

    // MARK: - Maintenance

    func clearCaches() async {
        videoInfoCache.removeAll()
        store.clearFeedCache()
        fileCache.clear()
        URLCache.shared.removeAllCachedResponses()
        await connect(showProgress: true)
    }

    func updateBundle() async throws -> BundleInfo {
        let info = try await bundles.download(from: settings.bundleURL)
        try await loadRuntime()
        await connect(showProgress: true)
        return info
    }

    func useBuiltInBundle() async {
        bundles.removeDownloadedBundle()
        do {
            try await loadRuntime()
            await connect(showProgress: true)
        } catch {
            phase = .failed(BridgeError.wrap(error))
        }
    }
}
