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
        VStack(spacing: 0) {
            Picker("Show", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 600)
            .padding(.top, 20)
            switch mode {
            case .videos:
                FeedView(feed: videos, emptyText: "No new videos from your subscriptions.")
            case .channels:
                FeedView(feed: channels, emptyText: "You aren't subscribed to any channels.")
            }
        }
    }
}
