import Foundation
import SwiftData
import Core

// MARK: - SwiftData models

/// Where older builds kept the settings; read once to move them to UserDefaults (see
/// `Store.loadSettings`). Kept in the schema so existing stores still open.
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

    /// Apple TV 4K (A15) measurements, September 2026: AV1/VP9 are decoded in software (no
    /// VideoToolbox support for either); 2160p30 AV1 plays with ~270% CPU and no drops, 2160p60
    /// drops 10-40% of its frames. So software formats go up to 2160p30 (1440p60 for 60 fps).
    static let softwareDecodeLimit = 3840.0 * 2160.0 * 30.0

    var quality: QualityPreferences {
        QualityPreferences(maxHeight: maxHeight,
                           decodeBudget: DecodeBudget(softwarePixelsPerSecond: Self.softwareDecodeLimit,
                                                      hardware: hardwareDecodeH264 ? [.avc] : []))
    }

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

extension AppSettings {
    /// Property-list form kept in UserDefaults. A missing or mistyped key keeps its default, so
    /// adding a setting later doesn't reset the others.
    init(dictionary d: [String: Any]) {
        self.init()
        if let v = d["streamClient"] as? String { streamClient = v }
        if let v = d["maxHeight"] as? Int { maxHeight = v }
        if let v = d["autoplay"] as? Bool { autoplay = v }
        if let v = d["captionsEnabled"] as? Bool { captionsEnabled = v }
        if let v = d["captionsLanguage"] as? String { captionsLanguage = v }
        if let v = d["playbackSpeed"] as? Double { playbackSpeed = v }
        if let v = d["bundleURL"] as? String { bundleURL = v }
        if let v = d["poTokenMode"] as? String { poTokenMode = v }
        if let v = d["visitorData"] as? String { visitorData = v }
        if let v = d["showStatsOverlay"] as? Bool { showStatsOverlay = v }
        if let v = d["hardwareDecodeH264"] as? Bool { hardwareDecodeH264 = v }
    }

    var dictionary: [String: Any] {
        [
            "streamClient": streamClient,
            "maxHeight": maxHeight,
            "autoplay": autoplay,
            "captionsEnabled": captionsEnabled,
            "captionsLanguage": captionsLanguage,
            "playbackSpeed": playbackSpeed,
            "bundleURL": bundleURL,
            "poTokenMode": poTokenMode,
            "visitorData": visitorData,
            "showStatsOverlay": showStatsOverlay,
            "hardwareDecodeH264": hardwareDecodeH264
        ]
    }
}

// MARK: - Store

/// Settings (UserDefaults) plus SwiftData access for resume positions and the feed cache.
@MainActor
final class Store {
    let container: ModelContainer?
    private let logs: LogBuffer
    private var context: ModelContext? { container?.mainContext }

    init(logs: LogBuffer) {
        self.logs = logs
        let schema = Schema([SettingsRecord.self, ResumeRecord.self, FeedCacheRecord.self])
        container = Store.makeContainer(schema: schema, logs: logs)
    }

    /// A tvOS app may only write to Library/Caches and tmp (plus about 500 KB of UserDefaults),
    /// and tvOS can purge Caches when storage runs low. So only data that may be lost lives in
    /// this store (resume positions, feed cache): in Caches, else tmp, else memory. The settings
    /// are in UserDefaults, which tvOS keeps.
    private static func makeContainer(schema: Schema, logs: LogBuffer) -> ModelContainer? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first { candidates.append(caches) }
        candidates.append(fm.temporaryDirectory)
        for (index, base) in candidates.enumerated() {
            let dir = base.appendingPathComponent("store", isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let config = ModelConfiguration("Tube", schema: schema, url: dir.appendingPathComponent("tube.store"), cloudKitDatabase: .none)
                let container = try ModelContainer(for: schema, configurations: [config])
                if index > 0 { logs.append(.warn, "The data store is in \(dir.path) instead.") }
                return container
            } catch {
                logs.append(.error, "Couldn't open the data store in \(dir.path): \(error.localizedDescription)")
            }
        }
        logs.append(.warn, "Resume positions and the feed cache are kept in memory only.")
        let memory = ModelConfiguration("TubeMemory", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [memory])
        } catch {
            logs.append(.error, "Couldn't create the in-memory data store: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Settings

    private static let settingsKey = "tube.settings"

    func loadSettings() -> AppSettings {
        let defaults = UserDefaults.standard
        var settings: AppSettings
        if let stored = defaults.dictionary(forKey: Self.settingsKey) {
            settings = AppSettings(dictionary: stored)
        } else {
            settings = legacySettings() ?? AppSettings()
            defaults.set(settings.dictionary, forKey: Self.settingsKey)
        }
        // Builds before 1.0.1 defaulted to the TV 7.x client and offered clients YouTube no longer
        // serves signed in; move every install to Automatic once (a later manual choice is kept),
        // and never keep a value the picker doesn't offer.
        let migrationKey = "tube.streamClient.autoMigration"
        let known = AppSettings.streamClients.map(\.id)
        if !defaults.bool(forKey: migrationKey) || !known.contains(settings.streamClient) {
            if settings.streamClient != "AUTO" {
                settings.streamClient = "AUTO"
                defaults.set(settings.dictionary, forKey: Self.settingsKey)
            }
            defaults.set(true, forKey: migrationKey)
        }
        return settings
    }

    func saveSettings(_ s: AppSettings) {
        UserDefaults.standard.set(s.dictionary, forKey: Self.settingsKey)
    }

    /// Settings an older build kept in the SwiftData store (which lives in purgeable Caches).
    private func legacySettings() -> AppSettings? {
        guard let context, let r = try? context.fetch(FetchDescriptor<SettingsRecord>()).first else { return nil }
        logs.append(.info, "Moved the settings from the data store to UserDefaults.")
        return AppSettings(streamClient: r.streamClient, maxHeight: r.maxHeight, autoplay: r.autoplay,
                           captionsEnabled: r.captionsEnabled, captionsLanguage: r.captionsLanguage,
                           playbackSpeed: r.playbackSpeed, bundleURL: r.bundleURL, poTokenMode: r.poTokenMode,
                           visitorData: r.visitorData, showStatsOverlay: r.showStatsOverlay,
                           hardwareDecodeH264: r.hardwareDecodeH264)
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
