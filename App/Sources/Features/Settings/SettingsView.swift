import SwiftUI
import Core
import Libmpv

/// The result of the last bundle download or switch. Kept outside SettingsView: installing a
/// bundle reconnects to YouTube, which rebuilds the whole tab view and this screen's state with
/// it, so a result written to @State would never be seen.
@MainActor
final class BundleUpdateStatus: ObservableObject {
    static let shared = BundleUpdateStatus()
    @Published var message: String?
    @Published var busy = false
}

struct SettingsView: View {
    /// The rows focus is sent to. Coming down from the tab bar lands on Re-enter cookies, the
    /// first row that does anything (the account row above it is only information), never on
    /// "Sign out" right under it. Coming back from what a row opened (a list of choices, the Debug
    /// screen, the keyboard, the Clear cache confirmation) lands on that row again.
    private enum Row: Hashable {
        case reenterCookies
        case maxQuality, streamClient, poTokens, captionLanguage, frameRate
        case bundleURL, clearCache, debug

        /// Opens a page on the Settings stack (or the keyboard) that focus comes back from.
        var opensPage: Bool {
            switch self {
            case .maxQuality, .streamClient, .poTokens, .captionLanguage, .frameRate, .bundleURL, .debug:
                return true
            case .reenterCookies, .clearCache:
                return false
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: Router
    @ObservedObject private var bundleUpdate = BundleUpdateStatus.shared
    @State private var confirmSignOut = false
    @State private var confirmClear = false
    @State private var cacheSize: Int64 = 0
    @FocusState private var focusedRow: Row?
    /// The row that last had focus (rows without a `Row` leave it as it was).
    @State private var lastRow: Row?
    /// The row that opened a page or confirmation, while focus is away on it; nil otherwise, and
    /// focus coming into the list lands on Re-enter cookies.
    @State private var returnRow: Row?
    @Environment(\.scenePhase) private var scenePhase
    /// Read when Settings appears and when the app comes back to the screen: it's switched in
    /// the Apple TV's own settings, outside the app.
    @State private var appleTVFrameRate: AppleTVFrameRateMatching?

    private let qualities = [2160, 1440, 1080, 720, 480]
    private let captionLanguages: [(String, String)] = [
        ("en", "English"), ("de", "German"), ("fr", "French"), ("es", "Spanish"), ("it", "Italian"),
        ("pt", "Portuguese"), ("nl", "Dutch"), ("pl", "Polish"), ("tr", "Turkish"), ("ru", "Russian"),
        ("hi", "Hindi"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese")
    ]

    private var qualityOptions: [ChoiceOption<Int>] {
        qualities.map { ChoiceOption(value: $0, label: label(forHeight: $0)) }
    }
    private var streamClientOptions: [ChoiceOption<String>] {
        AppSettings.streamClients.map { ChoiceOption(value: $0.id, label: $0.label) }
    }
    private var poTokenOptions: [ChoiceOption<String>] {
        [ChoiceOption(value: "auto", label: "Automatic"), ChoiceOption(value: "off", label: "Off")]
    }
    private var captionLanguageOptions: [ChoiceOption<String>] {
        captionLanguages.map { ChoiceOption(value: $0.0, label: $0.1) }
    }
    private var frameRateOptions: [ChoiceOption<FrameRateMatching>] {
        FrameRateMatching.allCases.map { ChoiceOption(value: $0, label: $0.label) }
    }

    var body: some View {
        Form {
            Section("Account") {
                if let account = model.account {
                    HStack(spacing: Theme.Spacing.titleToContent) {
                        RemoteImage(url: account.photo.flatMap(URL.init(string:)))
                            .frame(width: 70, height: 70)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: Theme.Spacing.textLines) {
                            Text(account.name)
                            if let handle = account.handle { Text(handle).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                } else {
                    Text(model.isSignedIn ? "Signed in (account name unavailable)" : "Not signed in")
                }
                Button("Re-enter cookies") { model.beginCookieReentry() }
                    .focused($focusedRow, equals: .reenterCookies)
                if model.isSignedIn {
                    // Deliberately not a `Row`: focus is never sent here, so after Cancel it may
                    // come back to Re-enter cookies instead.
                    Button { confirmSignOut = true } label: { DestructiveRowLabel("Sign out of this Apple TV") }
                }
            }

            Section {
                ChoiceRow("Maximum quality", selection: $model.settings.maxHeight, options: qualityOptions)
                    .focused($focusedRow, equals: .maxQuality)
                InfoRow("Codec order", value: "AV1 → VP9 → H.264")
                InfoRow("Audio", value: "Opus (highest bitrate), else AAC")
                Toggle("Hardware decoding for H.264", isOn: $model.settings.hardwareDecodeH264)
            } header: {
                Text("Quality rule")
            } footer: {
                Text("Always the highest resolution up to the maximum, never adaptive. AV1 and VP9 are decoded in software. Change the stream of a single video from the Quality button in the player.")
            }

            Section {
                ChoiceRow("Stream client", selection: $model.settings.streamClient, options: streamClientOptions)
                    .focused($focusedRow, equals: .streamClient)
                ChoiceRow("PO tokens (web clients)", selection: $model.settings.poTokenMode, options: poTokenOptions)
                    .focused($focusedRow, equals: .poTokens)
            } header: {
                Text("YouTube stream client")
            } footer: {
                Text("Automatic tries TV, TV as a Samsung set, Web embedded and Mobile web in turn, and keeps using the one that works. Only Mobile web needs a PO token; with PO tokens off, Automatic skips it.")
            }

            Section {
                Toggle("Autoplay next video", isOn: $model.settings.autoplay)
                Toggle("Captions on by default", isOn: $model.settings.captionsEnabled)
                ChoiceRow("Caption language", selection: $model.settings.captionsLanguage, options: captionLanguageOptions)
                    .focused($focusedRow, equals: .captionLanguage)
                Toggle("Show stats while playing", isOn: $model.settings.showStatsOverlay)
                // Last, right above the footer that explains it.
                ChoiceRow("Match frame rate", selection: $model.settings.frameRateMatching, options: frameRateOptions,
                          footer: Self.frameRateChoices)
                    .focused($focusedRow, equals: .frameRate)
            } header: {
                Text("Playback")
            } footer: {
                Text(frameRateFooter)
            }

            Section {
                InfoRow("Running bundle", value: model.bundleInfo.map { "\($0.bundleVersion)" } ?? "not loaded")
                InfoRow("Source", value: model.bundles.hasDownloadedBundle ? "Downloaded" : "Built into the app")
                TextField("Bundle URL", text: $model.settings.bundleURL)
                    .textContentType(.URL)
                    .focused($focusedRow, equals: .bundleURL)
                Button(bundleUpdate.busy ? "Downloading…" : "Download newer bundle") {
                    Task { await downloadBundle() }
                }
                .disabled(bundleUpdate.busy)
                if model.bundles.hasDownloadedBundle {
                    Button("Use the built-in bundle") {
                        Task { await useBuiltInBundle() }
                    }
                }
                if let message = bundleUpdate.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("YouTube bundle")
            } footer: {
                Text("YouTube changes often. A newer bundle can fix playback without reinstalling the app.")
            }

            Section("Storage") {
                InfoRow("Player & session cache", value: Formatters.bytes(cacheSize))
                Button {
                    returnRow = .clearCache
                    confirmClear = true
                } label: {
                    DestructiveRowLabel("Clear cache")
                }
                .focused($focusedRow, equals: .clearCache)
            }

            Section("Diagnostics") {
                NavigationLink("Debug screen") { DebugView() }
                    .focused($focusedRow, equals: .debug)
            }

            // Highlightable rows: this is the end of the list, and a tvOS list only scrolls as far
            // as the last row focus can reach.
            Section("About") {
                InfoRow("Tube", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                InfoRow("YouTube.js", value: model.bundleInfo?.youtubeiVersion ?? "?")
                InfoRow("libmpv client API", value: "\(mpv_client_api_version() >> 16).\(mpv_client_api_version() & 0xffff)")
            }
        }
        // Down from the tab bar went to whichever row tvOS picked, and on the TV that was
        // "Sign out", one press from signing out. As a focus section with a default, moving into
        // the list from the tab bar lands on Re-enter cookies; while a row's page or
        // confirmation is open, the default is that row, so coming back doesn't jump to the top.
        .focusSection()
        .defaultFocus($focusedRow, returnRow ?? Row.reenterCookies, priority: .userInitiated)
        .onChange(of: focusedRow) { _, row in
            guard let row else { return }
            lastRow = row
            returnRow = nil
        }
        .onDisappear {
            // A choice list, the Debug screen or the keyboard covered the list. (Switching to
            // another tab changes the selected tab first, and coming back from the tab bar should
            // land on Re-enter cookies again.)
            if router.selectedTab == .settings, let lastRow, lastRow.opensPage {
                returnRow = lastRow
            }
        }
        .confirmationDialog("Sign out?", isPresented: $confirmSignOut) {
            Button("Sign out", role: .destructive) { model.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the cookies from this Apple TV.")
        }
        .confirmationDialog("Clear the cache?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) {
                Task {
                    await model.clearCaches()
                    cacheSize = model.fileCache.totalBytes
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Feeds, thumbnails and the unlocked player script are downloaded again. Your sign-in stays.")
        }
        .task { cacheSize = model.fileCache.totalBytes }
        .onAppear { appleTVFrameRate = .current }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { appleTVFrameRate = .current }
        }
    }

    /// Under the list of Match frame rate values.
    private static let frameRateChoices = "Off: the TV stays at its usual refresh rate. 24 fps videos only: films and other 24 fps videos switch the TV to 24 Hz, everything else plays at the usual rate. All videos: 24 fps → 24 Hz, 25 and 50 fps → 50 Hz, 30 and 60 fps → 60 Hz."

    /// Why a switch can flicker and what it needs, plus a warning when the Apple TV won't let Tube
    /// switch at all, so choosing a mode that can't work doesn't look like a broken setting.
    private var frameRateFooter: String {
        let text = "Switching the TV's refresh rate makes some TVs flicker for a moment. 24 fps only switches just for films and other 24 fps videos. Needs Settings → Video and Audio → Match Content → Match Frame Rate on the Apple TV."
        guard model.settings.frameRateMatching != .off else { return text }
        switch appleTVFrameRate {
        case .off: return text + " It's off on this Apple TV right now, so the TV won't switch."
        case .unavailable: return text + " This tvOS doesn't let apps switch the refresh rate, so the TV won't switch."
        case .on, nil: return text
        }
    }

    private func label(forHeight height: Int) -> String {
        switch height {
        case 2160: return "4K (2160p)"
        case 1440: return "1440p"
        case 1080: return "1080p"
        default: return "\(height)p"
        }
    }

    // Both keep their own references: the view is torn down while they run.
    private func downloadBundle() async {
        let model = self.model
        let status = bundleUpdate
        status.busy = true
        status.message = "Downloading…"
        defer { status.busy = false }
        do {
            let info = try await model.updateBundle()
            if model.bundles.hasDownloadedBundle {
                status.message = "Installed \(info.bundleVersion) (YouTube.js \(info.youtubeiVersion))."
            } else {
                // The app falls back to the built-in bundle when the downloaded one doesn't start.
                status.message = "Update failed: the downloaded bundle \(info.bundleVersion) didn't start, so the app is still using the built-in one."
            }
        } catch {
            status.message = "Update failed: \(BridgeError.wrap(error).userMessage)"
        }
    }

    private func useBuiltInBundle() async {
        let model = self.model
        let status = bundleUpdate
        status.busy = true
        status.message = nil
        defer { status.busy = false }
        await model.useBuiltInBundle()
        if case .failed(let error) = model.phase {
            status.message = "The built-in bundle didn't start: \(error.userMessage)"
        } else {
            status.message = "Switched back to the built-in bundle."
        }
    }
}
