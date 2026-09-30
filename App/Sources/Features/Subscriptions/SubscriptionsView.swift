import SwiftUI
import Core

/// Subscriptions: the uploads feed and the grid of subscribed channels.
struct SubscriptionsView: View {
    enum Mode: String, CaseIterable {
        case videos = "Videos"
        case channels = "Channels"
    }

    @State private var mode: Mode = .videos
    @StateObject private var videos = FeedModel(cacheKey: "subscriptions", category: .subscriptions) { try await $0.subscriptions() }
    @StateObject private var channels = FeedModel(cacheKey: "subscribed-channels", category: .subscriptions) { try await $0.subscribedChannels() }

    var body: some View {
        // One list for both modes, with the picker as its header: it scrolls away with the cards
        // (so the tab bar can collapse), and it keeps its identity and focus when the mode changes,
        // since FeedView just loads the other model.
        FeedView(feed: mode == .videos ? videos : channels, emptyText: emptyText) {
            Picker("Show", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .listHeaderPicker()
        }
    }

    private var emptyText: String {
        switch mode {
        case .videos: return "No new videos from your subscriptions."
        case .channels: return "You aren't subscribed to any channels."
        }
    }
}
