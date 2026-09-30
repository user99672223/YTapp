import SwiftUI
import Core

/// Home: the account's recommendations (rows, grid and the Shorts shelf) with infinite scroll.
/// It opens straight on the cards, like Apple's own TV apps: the tab bar already says where you
/// are, and the signed-in account is shown in Settings.
struct HomeView: View {
    @StateObject private var feed = FeedModel(cacheKey: "home", category: .home) { try await $0.home() }

    var body: some View {
        FeedView(feed: feed, emptyText: "YouTube didn't return any recommendations. Watch a few videos and try again.")
    }
}
