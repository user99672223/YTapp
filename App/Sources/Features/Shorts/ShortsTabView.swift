import SwiftUI
import Core

/// The Shorts tab, like YouTube's own TV app: a centred welcome with "Watch now", which opens the
/// full-screen player (so Up/Down there never fight with the tab bar), and the Shorts from the
/// Home feed below it.
struct ShortsTabView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: Router
    @StateObject private var home = FeedModel(cacheKey: "home", category: .home) { try await $0.home() }
    @State private var contentWidth: CGFloat = Layout.defaultContentWidth

    /// The welcome fills most of the first screen under the tab bar; the grid's title shows
    /// below it, so it's clear there is more.
    private static let heroHeight: CGFloat = 760

    /// The columns fill the width between the margins exactly, so both sides match.
    private var shortWidth: CGFloat {
        Layout.columnWidth(in: contentWidth, count: Layout.shortColumns, spacing: Layout.shortSpacing)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(shortWidth), spacing: Layout.shortSpacing, alignment: .top), count: Layout.shortColumns)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.heroHeight)
                feed
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ContentWidthReader(width: $contentWidth))
                    // The tab isn't in a NavigationStack, so tvOS doesn't add its side margins.
                    .padding(.horizontal, Layout.screenMargin)
                    .padding(.bottom, Theme.Spacing.section)
            }
        }
        .task { await home.loadIfNeeded(model) }
    }

    private var hero: some View {
        VStack(spacing: Theme.Spacing.section) {
            VStack(spacing: Theme.Spacing.titleToContent) {
                HStack(spacing: Theme.Spacing.titleToContent) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: Theme.heroSymbolSize, weight: .semibold))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text("Shorts")
                        .font(.title.bold())
                }
                Text("Discover what's new & trending")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            Button {
                router.shorts = ShortsRequest(seedId: nil)
            } label: {
                Text("Watch now")
                    .font(.headline)
                    .frame(width: 520)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
    }

    @ViewBuilder
    private var feed: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.titleToContent) {
            Text("From your Home feed").font(.title3.bold())
            if let shorts = home.page?.shorts, !shorts.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: Layout.rowSpacing) {
                    ForEach(shorts, id: \.id) { short in
                        ShortCard(video: short, width: shortWidth)
                    }
                }
            } else if let error = home.error {
                ErrorStateView(error: error, isRetrying: home.isLoading) {
                    Task { await home.refresh(model, userInitiated: true) }
                }
                .frame(height: Layout.stateHeight)
            } else if home.page == nil || home.isLoading {
                LoadingView().frame(height: Layout.stateHeight)
            } else {
                EmptyStateView(systemImage: "bolt.horizontal", text: "Your Home feed has no Shorts right now.")
                    .frame(height: Layout.stateHeight)
            }
        }
    }
}
