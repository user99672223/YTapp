import SwiftUI
import Core

@MainActor
final class ChannelModel: ObservableObject {
    @Published var page: ChannelPage?
    @Published var error: BridgeError?
    @Published private(set) var isLoading = false
    @Published var isSubscribed: Bool?
    @Published var busy = false
    /// A failed Subscribe/Unsubscribe (shown with Retry). `error` is only for the page itself.
    @Published var actionError: BridgeError?
    @Published var tab: ChannelTab = .videos
    private var feeds: [ChannelTab: FeedModel] = [:]
    let channelId: String
    private var loadedAt: Date?

    init(channelId: String) {
        self.channelId = channelId
    }

    func load(_ model: AppModel, force: Bool = false) async {
        if !force, let loadedAt, RefreshPolicy.isFresh(fetchedAt: loadedAt, category: .channel), page != nil { return }
        if isLoading { return }
        if !force, page == nil, let cached = model.store.cachedPage("channel:\(channelId)", as: ChannelPage.self),
           RefreshPolicy.isFresh(fetchedAt: cached.fetchedAt, category: .channel) {
            // The key names a feed in the JS session that stored it; after a relaunch it's gone
            // or points at another channel, so the tabs fetch the channel themselves until the
            // fresh page (with a live key) arrives.
            var restored = cached.value
            restored.key = nil
            page = restored
            isSubscribed = restored.channel.isSubscribed
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await model.api { [channelId] in try await $0.channel(channelId) }
            page = fresh
            isSubscribed = fresh.channel.isSubscribed
            error = nil
            loadedAt = Date()
            model.store.storePage("channel:\(channelId)", fresh)
            if !fresh.tabs.isEmpty, !fresh.tabs.contains(tab) { tab = fresh.tabs[0] }
            // Keep the tab feeds already on screen; drop only tabs the channel no longer has.
            feeds = feeds.filter { fresh.tabs.isEmpty || fresh.tabs.contains($0.key) }
        } catch {
            if page == nil { self.error = BridgeError.wrap(error) }
        }
    }

    func feed(for tab: ChannelTab) -> FeedModel {
        if let existing = feeds[tab] { return existing }
        let id = channelId
        let feed = FeedModel(cacheKey: "channel:\(id):\(tab.rawValue)", category: .channel) { [weak self] service in
            // Read the key when the tab loads: the channel page may have been refreshed since.
            let key = await MainActor.run { self?.page?.key }
            return try await service.channelTab(channelId: id, tab: tab, key: key)
        }
        feeds[tab] = feed
        return feed
    }

    func toggleSubscription(_ model: AppModel) async {
        // The button stays enabled while busy (so it keeps focus); ignore presses until done.
        guard !busy else { return }
        guard let current = isSubscribed ?? page?.channel.isSubscribed else {
            await setSubscribed(true, model)
            return
        }
        await setSubscribed(!current, model)
    }

    private func setSubscribed(_ value: Bool, _ model: AppModel) async {
        busy = true
        defer { busy = false }
        do {
            let id = channelId
            isSubscribed = try await model.api { try await $0.setSubscribed(channelId: id, value) }
            actionError = nil
        } catch {
            actionError = BridgeError.wrap(error)
        }
    }
}

/// Channel page: a header with the banner, avatar, name, details and Subscribe, the Videos /
/// Shorts / Live / Playlists tabs below it, and the chosen tab's list under those.
struct ChannelView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var channel: ChannelModel
    /// The tab picker has focus. Only used to make it the page's first focus.
    @FocusState private var tabsFocused: Bool

    init(channelId: String) {
        _channel = StateObject(wrappedValue: ChannelModel(channelId: channelId))
    }

    var body: some View {
        Group {
            if channel.page != nil {
                // No .id(tab): FeedView loads whichever tab's model it's given, and the header
                // with the tab picker stays in place, so focus stays on the picker. Each tab
                // shows its own loading, empty and error (with Retry) state below it.
                FeedView(feed: channel.feed(for: channel.tab), emptyText: emptyText(for: channel.tab), emptySystemImage: "play.rectangle") {
                    ChannelPageHeader(channel: channel, tabsFocused: $tabsFocused)
                }
                // The page opens on the tabs rather than on Subscribe, the topmost control, so
                // Select on arrival never changes a subscription and Down reaches the first card.
                .defaultFocus($tabsFocused, true)
            } else if let error = channel.error {
                ErrorStateView(error: error, isRetrying: channel.isLoading) {
                    Task { await channel.load(model, force: true) }
                }
            } else {
                LoadingView()
            }
        }
        .task { await channel.load(model) }
        .alert("Couldn't change the subscription", isPresented: subscriptionFailed, presenting: channel.actionError) { _ in
            Button("Retry") { Task { await channel.toggleSubscription(model) } }
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.userMessage)
        }
    }

    private var subscriptionFailed: Binding<Bool> {
        Binding(get: { channel.actionError != nil }, set: { if !$0 { channel.actionError = nil } })
    }

    private func emptyText(for tab: ChannelTab) -> String {
        switch tab {
        case .videos: return "This channel hasn't uploaded any videos."
        case .shorts: return "This channel has no Shorts."
        case .live: return "This channel has no live streams."
        case .playlists: return "This channel has no playlists."
        }
    }
}

/// The top of a channel page: the avatar, name, details and Subscribe (over the channel's banner
/// when it has one), then the tab picker. Its own view observing the model, so Subscribe and the
/// picker redraw by themselves (FeedView keeps the header value it was built with).
private struct ChannelPageHeader: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var channel: ChannelModel
    var tabsFocused: FocusState<Bool>.Binding

    private static let avatarSize: CGFloat = 150
    /// YouTube banners are about 6:1; at this height across the list's width most of one shows
    /// above the avatar and name.
    private static let bannerHeight: CGFloat = 320

    private var info: ChannelHeader? { channel.page?.channel }
    private var tabs: [ChannelTab] { channel.page?.tabs ?? [] }
    private var bannerURL: URL? { info?.banner.flatMap(URL.init(string:)) }
    private var isSubscribed: Bool { channel.isSubscribed == true }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            identity
                // Full width, so Up from the tabs reaches Subscribe at the far end of the row.
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
            if tabs.count > 1 {
                Picker("Channel section", selection: $channel.tab) {
                    ForEach(tabs) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .focused(tabsFocused)
                // Leading, right above the list's first card, so Down from the tabs reaches that
                // card; the full-width focus section brings Up from any column (and Down from
                // Subscribe, at the trailing end of the header) to the tabs.
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
            }
        }
    }

    /// Avatar, name, details and Subscribe in one row. Over a banner the row sits at the banner's
    /// bottom, inset from its rounded edges; without one it lines up with the list below.
    private var identity: some View {
        HStack(spacing: Theme.Spacing.panel) {
            RemoteImage(url: info?.avatar.flatMap(URL.init(string:)))
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.textLines) {
                Text(info?.name ?? "Channel")
                    .font(.title2.bold())
                    .lineLimit(1)
                if !details.isEmpty {
                    Text(details)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !about.isEmpty {
                    Text(about)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, Theme.Spacing.textLines)
                }
            }
            Spacer(minLength: Theme.Spacing.section)
            if model.isSignedIn {
                subscribeButton
            }
        }
        .padding(bannerURL == nil ? 0 : Theme.Spacing.panel)
        .frame(maxWidth: .infinity, minHeight: bannerURL == nil ? nil : Self.bannerHeight, alignment: .bottomLeading)
        .background {
            if let bannerURL {
                ChannelBanner(url: bannerURL)
            }
        }
    }

    /// "@handle • 1.2M subscribers • 500 videos"
    private var details: String {
        [info?.handle, info?.subscriberCountText, info?.videoCountText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    /// The channel's description, trimmed (it often ends in blank lines).
    private var about: String {
        info?.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// A capsule, like YouTube's own: prominent red to subscribe, grey once subscribed. Always
    /// the same button (only its tint and label change), so focus stays on it.
    private var subscribeButton: some View {
        // Not disabled while busy: a disabled button loses focus on tvOS.
        Button {
            Task { await channel.toggleSubscription(model) }
        } label: {
            Label {
                Text(isSubscribed ? "Subscribed" : "Subscribe")
                    .lineLimit(1)
            } icon: {
                if channel.busy {
                    ProgressView()
                } else {
                    Image(systemName: isSubscribed ? "bell.fill" : "plus")
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(isSubscribed ? .gray : .red)
    }
}

/// A channel's banner behind the header: it fills the header and is cut to the app's banner
/// corners, darkened towards the bottom, where the avatar, name and Subscribe sit, so they read
/// well over any artwork. A banner that can't load leaves a plain dark panel (no photo glyph
/// behind the name).
private struct ChannelBanner: View {
    let url: URL

    var body: some View {
        Color.white.opacity(0.08)
            .overlay {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    }
                }
            }
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.1), location: 0),
                        .init(color: .black.opacity(0.55), location: 0.45),
                        .init(color: .black.opacity(0.85), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .continuousCorners(Theme.Radius.floating)
            .accessibilityHidden(true)
    }
}
