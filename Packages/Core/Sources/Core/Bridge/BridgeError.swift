import Foundation

/// Error categories reported by the JS bridge (js/src/bridge/errors.js).
public enum BridgeErrorKind: String, Codable, Sendable {
    case auth
    case loginRequired
    case botCheck
    case network
    case rateLimited
    case notFound
    case unavailable
    case upcoming
    case extraction
    case poToken
    case parse
    case expired
    case invalid
    case noSession
    case history
    case action
    case timeout
    case bridge
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BridgeErrorKind(rawValue: raw) ?? .unknown
    }
}

/// An error from the YouTube layer, with a plain-language message for the screen.
public struct BridgeError: Error, Codable, Hashable, Sendable, LocalizedError {
    public var kind: BridgeErrorKind
    public var message: String
    public var detail: String?
    public var status: Int?

    public init(kind: BridgeErrorKind, message: String, detail: String? = nil, status: Int? = nil) {
        self.kind = kind
        self.message = message
        self.detail = detail
        self.status = status
    }

    public var errorDescription: String? { userMessage }

    /// Errors that mean the cookies/session are no longer accepted.
    public var isAuthFailure: Bool { kind == .auth }

    public var title: String {
        switch kind {
        case .auth, .loginRequired: return "Sign-in problem"
        case .botCheck: return "YouTube wants a check"
        case .network, .timeout: return "Network problem"
        case .rateLimited: return "Too many requests"
        case .notFound: return "Not found"
        case .unavailable: return "Video unavailable"
        case .upcoming: return "Not live yet"
        case .extraction: return "Couldn't unlock the stream"
        case .poToken: return "Stream client problem"
        case .parse: return "Unexpected response"
        case .expired: return "This list expired"
        case .invalid: return "Something's missing"
        case .noSession: return "Not connected yet"
        case .history: return "History sync problem"
        case .action: return "That didn't work"
        case .bridge, .unknown: return "Something went wrong"
        }
    }

    /// A plain explanation plus what to do about it.
    public var userMessage: String {
        switch kind {
        case .auth:
            return "YouTube didn't accept your sign-in. If this keeps happening, go to Settings → Re-enter cookies."
        case .loginRequired:
            return message.isEmpty ? "You need to be signed in for this." : message
        case .botCheck:
            return "YouTube asked to confirm you're not a bot. Try again in a minute, switch the stream client in Settings, or re-enter fresh cookies."
        case .network, .timeout:
            return "Couldn't reach YouTube. Check the Apple TV's internet connection and try again."
        case .rateLimited:
            return "YouTube is limiting requests right now. Wait a minute and try again."
        case .extraction:
            return "YouTube changed how its streams are protected and this app couldn't unlock this one. Try again, pick another stream client in Settings, or update the YouTube bundle in Settings. (\(message))"
        case .poToken:
            return message
        case .expired:
            return "This list is out of date. Go back and open it again."
        case .noSession:
            return "The app is still connecting to YouTube. Wait a moment and try again."
        default:
            return message.isEmpty ? "Unknown error." : message
        }
    }

    public static func bridge(_ message: String) -> BridgeError {
        BridgeError(kind: .bridge, message: message)
    }

    /// Wraps any error into a BridgeError.
    public static func wrap(_ error: Error) -> BridgeError {
        if let e = error as? BridgeError { return e }
        if error is DecodingError {
            return BridgeError(kind: .parse, message: "The YouTube bundle returned data this app version doesn't understand.", detail: String(describing: error))
        }
        return BridgeError(kind: .unknown, message: error.localizedDescription, detail: String(describing: error))
    }
}
