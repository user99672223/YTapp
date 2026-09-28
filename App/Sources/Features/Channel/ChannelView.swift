import SwiftUI
import Core

@MainActor
final class ChannelModel: ObservableObject {
    @Published var page: ChannelPage?
    @Published var error: BridgeError?
    @Published private(set) var isLoading = false
    @Published var isSubscribed: Bool?
    @Published var busy = false
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
        } catch {
            self.error = BridgeError.wrap(error)
        }
    }
}

/// Channel page: banner, avatar, subscribe, and the Videos / Shorts / Live / Playlists tabs.
struct ChannelView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var channel: ChannelModel

    init(channelId: String) {
        _channel = StateObject(wrappedValue: ChannelModel(channelId: channelId))
    }

    var body: some View {
        Group {
            if let page = channel.page {
                // No .id(tab): FeedView loads whichever tab's model it's given, and the header
                // with the tab picker stays in place, so focus stays on the picker.
                FeedView(feed: channel.feed(for: channel.tab), emptyText: "This channel has nothing here.") {
                    header(page)
                }
            } else if let error = channel.error {
                ErrorStateView(error: error, isRetrying: channel.isLoading) {
                    Task { await channel.load(model, force: true) }
                }
            } else {
                LoadingView()
            }
        }
        .task { await channel.load(model) }
    }

    private func header(_ page: ChannelPage) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            if let banner = page.channel.banner, let url = URL(string: banner) {
                RemoteImage(url: url)
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            HStack(spacing: 36) {
                RemoteImage(url: page.channel.avatar.flatMap(URL.init(string:)))
                    .frame(width: 150, height: 150)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 8) {
                    Text(page.channel.name ?? "Channel").font(.title.bold())
                    Text([page.channel.handle, page.channel.subscriberCountText, page.channel.videoCountText]
                        .compactMap { $0 }.joined(separator: " • "))
                        .foregroundStyle(.secondary)
                    if let description = page.channel.description, !description.isEmpty {
                        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if model.isSignedIn {
                    Button {
                        Task { await channel.toggleSubscription(model) }
                    } label: {
                        Label(channel.isSubscribed == true ? "Subscribed" : "Subscribe",
                              systemImage: channel.isSubscribed == true ? "bell.fill" : "plus")
                    }
                    .disabled(channel.busy)
                    .tint(channel.isSubscribed == true ? .gray : .red)
                }
            }
            if page.tabs.count > 1 {
                Picker("Tab", selection: $channel.tab) {
                    ForEach(page.tabs) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 900)
            }
        }
    }
}
