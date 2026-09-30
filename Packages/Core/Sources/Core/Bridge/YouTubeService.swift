import Foundation

/// Transport to the JS bridge: calls `TubeBridge.call(id, method, argsJSON)` and returns the
/// result JSON (or throws a decoded `BridgeError`). Implemented by `JSRuntime` in the app and by
/// fakes in tests.
public protocol BridgeTransport: AnyObject, Sendable {
    func call(method: String, argsJSON: String) async throws -> Data
}

/// Typed async API over the JS bridge. All YouTube access in the app goes through this.
public final class YouTubeService: @unchecked Sendable {
    public let transport: BridgeTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(transport: BridgeTransport) {
        self.transport = transport
    }

    // MARK: - Plumbing

    public func call<T: Decodable>(_ method: String, _ args: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
        let json: String
        do {
            let data = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
            json = String(decoding: data, as: UTF8.self)
        } catch {
            throw BridgeError(kind: .invalid, message: "Couldn't encode the request for \(method).")
        }
        let data = try await transport.call(method: method, argsJSON: json)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw BridgeError(kind: .parse,
                              message: "The YouTube bundle returned data this app version doesn't understand (\(method)).",
                              detail: String(describing: error))
        }
    }

    private func encodable<E: Encodable>(_ value: E) throws -> Any {
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Session

    public func initialize(_ options: SessionOptions) async throws -> SessionSummary {
        try await call("init", try encodable(options) as? [String: Any] ?? [:])
    }

    public func validateCookie(_ cookie: String) async throws -> AccountInfo {
        try await call("validateCookie", ["cookie": cookie])
    }

    public func accountInfo() async throws -> AccountInfo {
        try await call("accountInfo")
    }

    public func bundleInfo() async throws -> BundleInfo {
        try await call("bundleInfo")
    }

    public func setClient(_ client: String, poTokenMode: String? = nil) async throws {
        var args: [String: Any] = ["client": client]
        if let poTokenMode { args["poTokenMode"] = poTokenMode }
        _ = try await call("setClient", args, as: IgnoredResult.self)
    }

    // MARK: - Feeds

    public func home() async throws -> FeedPage { try await call("home") }
    public func subscriptions() async throws -> FeedPage { try await call("subscriptions") }
    public func subscribedChannels() async throws -> FeedPage { try await call("subscribedChannels") }
    public func history() async throws -> FeedPage { try await call("history") }
    public func playlists() async throws -> FeedPage { try await call("playlists") }

    public func more(_ key: String) async throws -> FeedPage {
        try await call("more", ["key": key])
    }

    public func searchSuggestions(_ query: String) async throws -> [String] {
        try await call("searchSuggestions", ["query": query])
    }

    public func search(_ query: String, filters: SearchFilters = SearchFilters()) async throws -> FeedPage {
        try await call("search", ["query": query, "filters": try encodable(filters)])
    }

    public func channel(_ id: String) async throws -> ChannelPage {
        try await call("channel", ["id": id])
    }

    public func channelTab(channelId: String, tab: ChannelTab, key: String?) async throws -> FeedPage {
        var args: [String: Any] = ["id": channelId, "tab": tab.rawValue]
        if let key { args["key"] = key }
        return try await call("channelTab", args)
    }

    public func playlist(_ id: String) async throws -> PlaylistPage {
        try await call("playlist", ["id": id])
    }

    // MARK: - Watch

    public func videoInfo(_ id: String, client: String) async throws -> VideoDetails {
        try await call("videoInfo", ["id": id, "client": client])
    }

    /// The itags let the bridge check that each index still points at the format chosen here; if
    /// the video was loaded again since, it answers `.expired` and the caller fetches the details again.
    public func resolveFormats(videoId: String, formats: [StreamFormat]) async throws -> ResolvedStreams {
        try await call("resolveFormats", ["id": videoId, "indices": formats.map(\.index), "itags": formats.map(\.itag)])
    }

    public func markWatched(videoId: String) async throws -> PingResult {
        try await call("markWatched", ["id": videoId])
    }

    public func watchtime(videoId: String, report: WatchTimeReport) async throws -> PingResult {
        var args = report.bridgeArguments
        args["id"] = videoId
        return try await call("watchtime", args)
    }

    // MARK: - Shorts

    public func shortsFeed(seedId: String?) async throws -> ShortsSequence {
        var args: [String: Any] = [:]
        if let seedId { args["seedId"] = seedId }
        return try await call("shortsFeed", args)
    }

    public func shortsMore(_ key: String) async throws -> ShortsSequence {
        try await call("shortsMore", ["key": key])
    }

    public func shortInfo(_ id: String, client: String) async throws -> ShortDetails {
        try await call("shortInfo", ["id": id, "client": client])
    }

    // MARK: - Actions

    public func rate(videoId: String, _ status: LikeStatus) async throws -> LikeStatus {
        let result: RateResult = try await call("rate", ["id": videoId, "rating": status.rawValue])
        return result.likeStatus
    }

    public func setSubscribed(channelId: String, _ subscribed: Bool) async throws -> Bool {
        let result: SubscribeResult = try await call("subscribe", ["channelId": channelId, "subscribe": subscribed])
        return result.isSubscribed
    }

    public func setWatchLater(videoId: String, _ add: Bool) async throws -> Bool {
        let result: WatchLaterResult = try await call("watchLater", ["id": videoId, "add": add])
        return result.inWatchLater ?? add
    }

    public func watchLaterStatus(videoId: String) async throws -> Bool? {
        let result: WatchLaterResult = try await call("watchLaterStatus", ["id": videoId])
        return result.inWatchLater
    }

    public func comments(videoId: String, sort: CommentSort = .top) async throws -> CommentsPage {
        try await call("comments", ["videoId": videoId, "sort": sort.rawValue])
    }

    public func moreComments(_ key: String) async throws -> CommentsPage {
        try await call("commentsMore", ["key": key])
    }

    /// The first replies to a top-level comment; `key` is the section's `CommentsPage.key`.
    public func commentReplies(key: String, commentId: String) async throws -> CommentRepliesPage {
        try await call("commentReplies", ["key": key, "commentId": commentId])
    }

    public func moreCommentReplies(_ key: String) async throws -> CommentRepliesPage {
        try await call("commentRepliesMore", ["key": key])
    }

    public func postComment(videoId: String, text: String) async throws {
        let _: PostCommentResult = try await call("postComment", ["videoId": videoId, "text": text])
    }
}

/// For calls whose result the app ignores.
public struct IgnoredResult: Decodable, Sendable {
    public init(from decoder: Decoder) throws {}
}
