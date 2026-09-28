import SwiftUI
import Core

/// CPU, memory, chosen formats, buffer state, bridge state and recent logs.
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
                LabeledContent("CPU (all threads)", value: String(format: "%.0f%%", cpu) + " of \(ProcessStats.coreCount * 100)%")
                LabeledContent("Memory", value: Formatters.bytes(Int64(memory)))
                LabeledContent("Match frame rate", value: DisplayCriteriaController.isMatchingEnabled ? "On" : "Off — enable in Apple TV Settings → Video and Audio → Match Content")
            }
            Section("Last playback") {
                let s = diagnostics.snapshot
                if s.videoId.isEmpty {
                    Text("Nothing played yet in this session.").foregroundStyle(.secondary)
                } else {
                    LabeledContent("Video", value: s.title.isEmpty ? s.videoId : s.title)
                    LabeledContent("Stream client", value: s.client)
                    LabeledContent("Chosen formats", value: s.selection)
                    LabeledContent("Decoder", value: "\(s.stats.videoCodec) · hwdec \(s.stats.hwdec.isEmpty ? "no" : s.stats.hwdec)")
                    LabeledContent("Resolution", value: "\(s.stats.width)×\(s.stats.height) @ " + String(format: "%.3f fps", s.stats.containerFps))
                    LabeledContent("Display", value: s.refreshRate.map { String(format: "%.3f Hz", $0) } ?? "unchanged")
                    LabeledContent("Buffer", value: String(format: "%.0f s ahead · %@ cached · %@/s", s.stats.bufferedSeconds,
                                                             Formatters.bytes(Int64(s.stats.demuxerCacheBytes)),
                                                             Formatters.bytes(Int64(s.stats.cacheSpeed))))
                    LabeledContent("Buffering", value: s.isBuffering ? "yes (\(s.stats.bufferingPercent)%)" : "no")
                    LabeledContent("Dropped frames", value: "\(s.stats.droppedFrames) output · \(s.stats.decoderDroppedFrames) decoder")
                    LabeledContent("Position", value: "\(Formatters.duration(s.position)) / \(Formatters.duration(s.duration))")
                    LabeledContent("History sync", value: s.history.isEmpty ? "—" : s.history)
                    if let error = s.error { LabeledContent("Error", value: error) }
                }
            }
            Section("YouTube bridge") {
                LabeledContent("Bundle", value: model.bundleInfo?.bundleVersion ?? "not loaded")
                LabeledContent("Signed in", value: model.session?.loggedIn == true ? "yes" : "no")
                LabeledContent("Player script", value: model.session?.playerId.map { "\($0) · decipher \(model.session?.hasDecipher == true ? "ready" : "missing")" } ?? "—")
                if !bridgeState.isEmpty { Text(bridgeState).font(.caption.monospaced()) }
                Button("Check bridge state") { Task { await checkBridge() } }
                Button("Reconnect to YouTube") { Task { await model.connect(showProgress: false); await checkBridge() } }
            }
            Section("Recent log") {
                ForEach(lines.reversed().prefix(120)) { line in
                    Text("[\(line.level.rawValue)] \(line.text)")
                        .font(.system(size: 18, design: .monospaced))
                        .foregroundStyle(line.level == .error ? .red : line.level == .warn ? .yellow : .secondary)
                        .lineLimit(4)
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
