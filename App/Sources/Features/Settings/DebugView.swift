import SwiftUI
import Core

/// CPU, memory, frame-rate matching, chosen formats, buffer state, bridge state and recent logs.
/// Every row can be highlighted (`InfoRow`, and the log lines alike): on tvOS a list only scrolls
/// by moving focus, so rows that can't take focus (the device info, the log) could never be
/// scrolled into view, and with nothing to highlight Menu would leave the app instead of going
/// back to Settings.
struct DebugView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var diagnostics = PlaybackDiagnostics.shared
    @State private var cpu: Double = 0
    @State private var memory: UInt64 = 0
    @State private var lines: [LogBuffer.Line] = []
    @State private var bridgeState = ""

    var body: some View {
        List {
            Section("Device") {
                InfoRow("CPU (all threads)", value: String(format: "%.0f%%", cpu) + " of \(ProcessStats.coreCount * 100)%")
                InfoRow("Memory", value: Formatters.bytes(Int64(memory)))
            }
            // Tube's own setting next to the Apple TV's switch it depends on: tvOS ignores Tube's
            // requests unless that one is on too.
            Section("Match frame rate") {
                InfoRow("Tube setting", value: model.settings.frameRateMatching.label)
                InfoRow("Apple TV", value: DisplayCriteriaController.status)
            }
            Section("Last playback") {
                let s = diagnostics.snapshot
                if s.videoId.isEmpty {
                    TextRow("Nothing played yet in this session.")
                } else {
                    InfoRow("Video", value: s.title.isEmpty ? s.videoId : s.title)
                    InfoRow("Stream client", value: s.client)
                    InfoRow("Chosen formats", value: s.selection)
                    InfoRow("Decoder", value: "\(s.stats.videoCodec) · hwdec \(s.stats.hwdec.isEmpty ? "no" : s.stats.hwdec)")
                    InfoRow("Resolution", value: "\(s.stats.width)×\(s.stats.height) @ " + String(format: "%.3f fps", s.stats.containerFps))
                    InfoRow("Display", value: s.refreshRate.map { String(format: "%.3f Hz", $0) } ?? "TV's own rate")
                    InfoRow("Buffer", value: String(format: "%.0f s ahead · %@ cached · %@/s", s.stats.bufferedSeconds,
                                                    Formatters.bytes(Int64(s.stats.demuxerCacheBytes)),
                                                    Formatters.bytes(Int64(s.stats.cacheSpeed))))
                    InfoRow("Buffering", value: s.isBuffering ? "yes (\(s.stats.bufferingPercent)%)" : "no")
                    InfoRow("Dropped frames", value: "\(s.stats.droppedFrames) output · \(s.stats.decoderDroppedFrames) decoder")
                    InfoRow("Position", value: "\(Formatters.duration(s.position)) / \(Formatters.duration(s.duration))")
                    InfoRow("History sync", value: s.history.isEmpty ? "—" : s.history)
                    if let error = s.error { InfoRow("Error", value: error) }
                }
            }
            Section("YouTube bridge") {
                InfoRow("Bundle", value: model.bundleInfo?.bundleVersion ?? "not loaded")
                InfoRow("Signed in", value: model.session?.loggedIn == true ? "yes" : "no")
                InfoRow("Player script", value: model.session?.playerId.map { "\($0) · decipher \(model.session?.hasDecipher == true ? "ready" : "missing")" } ?? "—")
                if !bridgeState.isEmpty { TextRow(bridgeState, monospaced: true) }
                Button("Check bridge state") { Task { await checkBridge() } }
                Button("Reconnect to YouTube") { Task { await model.connect(showProgress: false); await checkBridge() } }
            }
            Section("Recent log") {
                ForEach(lines.reversed().prefix(120)) { line in
                    Button {} label: { LogLineLabel(line: line) }
                }
            }
        }
        .navigationTitle("Debug")
        .task {
            while !Task.isCancelled {
                cpu = ProcessStats.cpuPercent()
                memory = ProcessStats.memoryFootprint()
                lines = model.logs.snapshot
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func checkBridge() async {
        do {
            let data = try await model.api { service in try await service.transport.call(method: "sessionState", argsJSON: "{}") }
            bridgeState = String(decoding: data, as: UTF8.self)
        } catch {
            bridgeState = "Bridge error: \(BridgeError.wrap(error).userMessage)"
        }
    }
}

/// A row of plain text that can be highlighted, like `InfoRow`.
private struct TextRow: View {
    let text: String
    var monospaced = false

    init(_ text: String, monospaced: Bool = false) {
        self.text = text
        self.monospaced = monospaced
    }

    var body: some View {
        Button {} label: {
            Text(text)
                .font(monospaced ? Font.caption.monospaced() : Font.body)
                .foregroundStyle(.secondary)
        }
    }
}

/// One log line in the smallest text style. Errors and warnings keep their colour on the white
/// row of a focused line by turning darker, as `DestructiveRowLabel` does: bright red and yellow
/// can't be read on it.
private struct LogLineLabel: View {
    let line: LogBuffer.Line
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Text("[\(line.level.rawValue)] \(line.text)")
            .font(.caption2.monospaced())
            .foregroundStyle(color)
            .lineLimit(4)
    }

    private var color: Color {
        switch line.level {
        case .error: return isFocused ? Color(red: 0.7, green: 0.05, blue: 0.05) : .red
        case .warn: return isFocused ? Color(red: 0.5, green: 0.35, blue: 0) : .yellow
        case .info, .debug: return .secondary
        }
    }
}
