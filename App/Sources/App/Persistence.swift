import Foundation
import SwiftData
import Core

// MARK: - SwiftData models

@Model
final class SettingsRecord {
    var streamClient: String = "AUTO"
    var maxHeight: Int = 2160
    var autoplay: Bool = true
    var captionsEnabled: Bool = false
    var captionsLanguage: String = "en"
    var playbackSpeed: Double = 1.0
    var bundleURL: String = "https://raw.githubusercontent.com/user99672223/YTapp/main/App/Resources/js/youtubei.bundle.js"
    var poTokenMode: String = "auto"
    var visitorData: String = ""
    var showStatsOverlay: Bool = false
    var hardwareDecodeH264: Bool = true

    init() {}
}

@Model
final class ResumeRecord {
    @Attribute(.unique) var videoId: String
    var position: Double
    var duration: Double
    var updatedAt: Date

    init(videoId: String, position: Double, duration: Double, updatedAt: Date = Date()) {
        self.videoId = videoId
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }
}

@Model
final class FeedCacheRecord {
    @Attribute(.unique) var key: String
    var payload: Data
    var fetchedAt: Date

    init(key: String, payload: Data, fetchedAt: Date = Date()) {
        self.key = key
        self.payload = payload
        self.fetchedAt = fetchedAt
    }
}

/// Plain value copy of the settings used across the app.
struct AppSettings: Equatable {
    var streamClient: String = "AUTO"
    var maxHeight: Int = 2160
    var autoplay: Bool = true
    var captionsEnabled: Bool = false
    var captionsLanguage: String = "en"
    var playbackSpeed: Double = 1.0
    var bundleURL: String = BundleManager.defaultUpdateURL
    var poTokenMode: String = "auto"
    var visitorData: String = ""
    var showStatsOverlay: Bool = false
    var hardwareDecodeH264: Bool = true

    // EXPERIMENT: VP9 first when the TV decodes it in hardware.
    var quality: QualityPreferences { QualityPreferences(maxHeight: maxHeight, codecOrder: DecoderSupport.vp9 ? [.vp9, .av1, .avc] : [.av1, .vp9, .avc]) }

    /// Clients that accept the account cookies and return direct stream URLs (September 2026).
    /// TV_SIMPLY, ANDROID_VR, IOS, VISIONOS and TV_EMBEDDED no longer work signed in; WEB is SABR-only.
    static let streamClients: [(id: String, label: String)] = [
        ("AUTO", "Automatic (recommended)"),
        ("TV", "TV"),
        ("TV_TIZEN", "TV (Samsung identity)"),
        ("WEB_EMBEDDED", "Web embedded"),
        ("MWEB", "Mobile web (PO token)")
    ]
}

// MARK: - Store

/// SwiftData access for settings, resume positions and the feed cache.
@MainActor
final class Store {
    let container: ModelContainer?
    private var context: ModelContext? { container?.mainContext }

    init() {
        let schema = Schema([SettingsRecord.self, ResumeRecord.self, FeedCacheRecord.self])
        container = Store.makeContainer(schema: schema)
    }

    /// tvOS keeps Application Support for small data; fall back to Caches, then memory.
    private static func makeContainer(schema: Schema) -> ModelContainer? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first { candidates.append(support) }
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first { candidates.append(caches) }
        for base in candidates {
            let dir = base.appendingPathComponent("store", isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let config = ModelConfiguration("Tube", schema: schema, url: dir.appendingPathComponent("tube.store"), cloudKitDatabase: .none)
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                continue
            }
        }
        let memory = ModelConfiguration("TubeMemory", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try? ModelContainer(for: schema, configurations: [memory])
    }

    // MARK: Settings

    private func settingsRecord() -> SettingsRecord? {
        guard let context else { return nil }
        if let existing = try? context.fetch(FetchDescriptor<SettingsRecord>()).first { return existing }
        let record = SettingsRecord()
        context.insert(record)
        try? context.save()
        return record
    }

    func loadSettings() -> AppSettings {
        guard let r = settingsRecord() else { return AppSettings() }
        // Builds before 1.0.1 defaulted to the TV 7.x client and offered clients YouTube no longer
        // serves signed in; move every install to Automatic once (a later manual choice is kept),
        // and never keep a value the picker doesn't offer.
        let migrationKey = "tube.streamClient.autoMigration"
        let known = AppSettings.streamClients.map(\.id)
        if !UserDefaults.standard.bool(forKey: migrationKey) || !known.contains(r.streamClient) {
            if r.streamClient != "AUTO" {
                r.streamClient = "AUTO"
                try? context?.save()
            }
            UserDefaults.standard.set(true, forKey: migrationKey)
        }
        return AppSettings(streamClient: r.streamClient, maxHeight: r.maxHeight, autoplay: r.autoplay,
                           captionsEnabled: r.captionsEnabled, captionsLanguage: r.captionsLanguage,
                           playbackSpeed: r.playbackSpeed, bundleURL: r.bundleURL, poTokenMode: r.poTokenMode,
                           visitorData: r.visitorData, showStatsOverlay: r.showStatsOverlay,
                           hardwareDecodeH264: r.hardwareDecodeH264)
    }

    func saveSettings(_ s: AppSettings) {
        guard let r = settingsRecord() else { return }
        r.streamClient = s.streamClient
        r.maxHeight = s.maxHeight
        r.autoplay = s.autoplay
        r.captionsEnabled = s.captionsEnabled
        r.captionsLanguage = s.captionsLanguage
        r.playbackSpeed = s.playbackSpeed
        r.bundleURL = s.bundleURL
        r.poTokenMode = s.poTokenMode
        r.visitorData = s.visitorData
        r.showStatsOverlay = s.showStatsOverlay
        r.hardwareDecodeH264 = s.hardwareDecodeH264
        try? context?.save()
    }

    // MARK: Resume positions

    func resumePosition(for videoId: String) -> ResumeRecord? {
        guard let context else { return nil }
        var descriptor = FetchDescriptor<ResumeRecord>(predicate: #Predicate { $0.videoId == videoId })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func saveResume(videoId: String, position: Double, duration: Double) {
        guard let context else { return }
        if ResumePolicy.isFinished(position: position, duration: duration) || position < ResumePolicy.minimumResume {
            if let existing = resumePosition(for: videoId) {
                context.delete(existing)
                try? context.save()
            }
            return
        }
        if let existing = resumePosition(for: videoId) {
            existing.position = position
            existing.duration = duration
            existing.updatedAt = Date()
        } else {
            context.insert(ResumeRecord(videoId: videoId, position: position, duration: duration))
        }
        try? context.save()
        pruneResumeRecords()
    }

    private func pruneResumeRecords(keep: Int = 500) {
        guard let context else { return }
        var descriptor = FetchDescriptor<ResumeRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchOffset = keep
        if let old = try? context.fetch(descriptor), !old.isEmpty {
            old.forEach { context.delete($0) }
            try? context.save()
        }
    }

    // MARK: Feed cache

    func cachedPage<T: Decodable>(_ key: String, as type: T.Type) -> (value: T, fetchedAt: Date)? {
        guard let context else { return nil }
        var descriptor = FetchDescriptor<FeedCacheRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let record = try? context.fetch(descriptor).first,
              let value = try? JSONDecoder().decode(T.self, from: record.payload) else { return nil }
        return (value, record.fetchedAt)
    }

    func storePage<T: Encodable>(_ key: String, _ value: T) {
        guard let context, let data = try? JSONEncoder().encode(value) else { return }
        var descriptor = FetchDescriptor<FeedCacheRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.payload = data
            existing.fetchedAt = Date()
        } else {
            context.insert(FeedCacheRecord(key: key, payload: data))
        }
        try? context.save()
    }

    func clearFeedCache() {
        guard let context else { return }
        try? context.delete(model: FeedCacheRecord.self)
        try? context.save()
    }

    func clearResumePositions() {
        guard let context else { return }
        try? context.delete(model: ResumeRecord.self)
        try? context.save()
    }
}
