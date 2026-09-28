import Foundation
import JavaScriptCore
import Core

/// Chooses which youtubei bundle to run: a newer one downloaded from Settings or the one built
/// into the app. A tvOS app may only write to Library/Caches and tmp, so the download is kept in
/// Caches/bundles; if tvOS purges it, the built-in bundle is used again.
final class BundleManager: @unchecked Sendable {
    static let defaultUpdateURL = "https://raw.githubusercontent.com/user99672223/YTapp/main/App/Resources/js/youtubei.bundle.js"

    private let directory: URL
    private let logs: LogBuffer
    private var downloadedURL: URL { directory.appendingPathComponent("youtubei.bundle.js") }

    init(logs: LogBuffer) {
        self.logs = logs
        let base: URL
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            base = caches
        } else {
            base = FileManager.default.temporaryDirectory
            logs.append(.warn, "No Caches folder; a downloaded bundle is kept in \(base.path) instead.")
        }
        directory = base.appendingPathComponent("bundles", isDirectory: true)
    }

    var builtInURL: URL? {
        Bundle.main.url(forResource: "youtubei.bundle", withExtension: "js")
    }

    var hasDownloadedBundle: Bool {
        FileManager.default.fileExists(atPath: downloadedURL.path)
    }

    /// The bundle to load: downloaded if present, otherwise the built-in one.
    var activeURL: URL? {
        hasDownloadedBundle ? downloadedURL : builtInURL
    }

    func removeDownloadedBundle() {
        try? FileManager.default.removeItem(at: downloadedURL)
    }

    /// Downloads a bundle, checks that it loads and speaks the same bridge protocol, then
    /// installs it. Returns the new bundle's version info.
    func download(from urlString: String) async throws -> BundleInfo {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw BridgeError(kind: .invalid, message: "That isn't a valid http(s) URL.")
        }
        // Checked first, so a folder that can't be written fails before the download and the
        // costly evaluation.
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            logs.append(.error, "Couldn't create the bundle folder \(directory.path): \(error.localizedDescription)")
            throw BridgeError(kind: .bridge, message: "This Apple TV didn't let the app save the bundle (\(error.localizedDescription)).")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw BridgeError(kind: .network, message: "Download failed (HTTP \(http.statusCode)).")
        }
        guard data.count > 100_000, let code = String(data: data, encoding: .utf8), code.contains("TubeBridge") else {
            throw BridgeError(kind: .invalid, message: "That file isn't a Tube YouTube bundle.")
        }
        let info = try Self.validate(code: code)
        let temp = directory.appendingPathComponent("download.tmp")
        try data.write(to: temp, options: .atomic)
        if hasDownloadedBundle { try FileManager.default.removeItem(at: downloadedURL) }
        try FileManager.default.moveItem(at: temp, to: downloadedURL)
        return info
    }

    /// Evaluates the bundle in a scratch context without natives and reads its version.
    static func validate(code: String) throws -> BundleInfo {
        guard let context = JSContext() else { throw BridgeError(kind: .bridge, message: "JavaScriptCore unavailable.") }
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        context.evaluateScript(code)
        guard let info = context.objectForKeyedSubscript("TubeBridge")?.objectForKeyedSubscript("bundleInfo"), info.isObject else {
            throw BridgeError(kind: .invalid, message: "The bundle didn't start: \(failure ?? "TubeBridge missing").")
        }
        let proto = Int(info.objectForKeyedSubscript("protocol")?.toInt32() ?? 0)
        guard proto == 1 else {
            throw BridgeError(kind: .invalid, message: "This bundle needs a different app version (bridge protocol \(proto)).")
        }
        return BundleInfo(
            bundleVersion: info.objectForKeyedSubscript("bundleVersion")?.toString() ?? "?",
            youtubeiVersion: info.objectForKeyedSubscript("youtubeiVersion")?.toString() ?? "?",
            bgutilsVersion: info.objectForKeyedSubscript("bgutilsVersion")?.toString(),
            protocol: proto
        )
    }
}
