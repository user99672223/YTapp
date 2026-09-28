import SwiftUI
import Core

/// Home: the account's recommendations (rows, grid and the Shorts shelf) with infinite scroll.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var feed = FeedModel(cacheKey: "home", category: .home) { try await $0.home() }

    var body: some View {
        FeedView(feed: feed, emptyText: "YouTube didn't return any recommendations. Watch a few videos and try again.") {
            HStack {
                if let account = model.account {
                    RemoteImage(url: account.photo.flatMap(URL.init(string:)))
                        .frame(width: 60, height: 60)
                        .clipShape(Circle())
                    Text(account.name).font(.headline).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}
