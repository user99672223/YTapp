import SwiftUI
import Core
import Libmpv

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var bundleStatus: String?
    @State private var bundleBusy = false
    @State private var confirmSignOut = false
    @State private var confirmClear = false
    @State private var cacheSize: Int64 = 0

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

    var body: some View {
        Form {
            Section("Account") {
                if let account = model.account {
                    HStack(spacing: 24) {
                        RemoteImage(url: account.photo.flatMap(URL.init(string:)))
                            .frame(width: 70, height: 70)
                            .clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(account.name)
                            if let handle = account.handle { Text(handle).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                } else {
                    Text(model.isSignedIn ? "Signed in (account name unavailable)" : "Not signed in")
                }
                Button("Re-enter cookies") { model.beginCookieReentry() }
                if model.isSignedIn {
                    Button { confirmSignOut = true } label: { DestructiveRowLabel("Sign out of this Apple TV") }
                }
            }

            Section {
                ChoiceRow("Maximum quality", selection: $model.settings.maxHeight, options: qualityOptions)
                LabeledContent("Codec order", value: "AV1 → VP9 → H.264")
                LabeledContent("Audio", value: "Opus (highest bitrate), else AAC")
                Toggle("Hardware decoding for H.264", isOn: $model.settings.hardwareDecodeH264)
            } header: {
                Text("Quality rule")
            } footer: {
                Text("Always the highest resolution up to the maximum, never adaptive. AV1 and VP9 are decoded in software. Change the stream of a single video from the Quality button in the player.")
            }

            Section {
                ChoiceRow("Stream client", selection: $model.settings.streamClient, options: streamClientOptions)
                ChoiceRow("PO tokens (web clients)", selection: $model.settings.poTokenMode, options: poTokenOptions)
            } header: {
                Text("YouTube stream client")
            } footer: {
                Text("Automatic tries TV, TV as a Samsung set, Web embedded and Mobile web in turn, and keeps using the one that works. Only Mobile web needs a PO token.")
            }

            Section("Playback") {
                Toggle("Autoplay next video", isOn: $model.settings.autoplay)
                Toggle("Captions on by default", isOn: $model.settings.captionsEnabled)
                ChoiceRow("Caption language", selection: $model.settings.captionsLanguage, options: captionLanguageOptions)
                Toggle("Show stats while playing", isOn: $model.settings.showStatsOverlay)
            }

            Section {
                LabeledContent("Running bundle", value: model.bundleInfo.map { "\($0.bundleVersion)" } ?? "not loaded")
                LabeledContent("Source", value: model.bundles.hasDownloadedBundle ? "Downloaded" : "Built into the app")
                TextField("Bundle URL", text: $model.settings.bundleURL)
                    .textContentType(.URL)
                Button(bundleBusy ? "Downloading…" : "Download newer bundle") {
                    Task { await downloadBundle() }
                }
                .disabled(bundleBusy)
                if model.bundles.hasDownloadedBundle {
                    Button("Use the built-in bundle") {
                        Task {
                            bundleBusy = true
                            await model.useBuiltInBundle()
                            bundleBusy = false
                            bundleStatus = "Switched back to the built-in bundle."
                        }
                    }
                }
                if let bundleStatus {
                    Text(bundleStatus).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("YouTube bundle")
            } footer: {
                Text("YouTube changes often. A newer bundle can fix playback without reinstalling the app.")
            }

            Section("Storage") {
                LabeledContent("Player & session cache", value: Formatters.bytes(cacheSize))
                Button { confirmClear = true } label: { DestructiveRowLabel("Clear cache") }
            }

            Section("Diagnostics") {
                NavigationLink("Debug screen") { DebugView() }
            }

            Section("About") {
                LabeledContent("Tube", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                LabeledContent("YouTube.js", value: model.bundleInfo?.youtubeiVersion ?? "?")
                LabeledContent("libmpv client API", value: "\(mpv_client_api_version() >> 16).\(mpv_client_api_version() & 0xffff)")
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
    }

    private func label(forHeight height: Int) -> String {
        switch height {
        case 2160: return "4K (2160p)"
        case 1440: return "1440p"
        case 1080: return "1080p"
        default: return "\(height)p"
        }
    }

    private func downloadBundle() async {
        bundleBusy = true
        bundleStatus = "Downloading…"
        defer { bundleBusy = false }
        do {
            let info = try await model.updateBundle()
            bundleStatus = "Installed \(info.bundleVersion) (YouTube.js \(info.youtubeiVersion))."
        } catch {
            bundleStatus = "Update failed: \(BridgeError.wrap(error).userMessage)"
        }
    }
}
