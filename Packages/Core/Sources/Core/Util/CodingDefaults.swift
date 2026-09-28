import Foundation

/// A `Bool` that decodes to `false` when the key is missing or null (the JS bridge drops
/// undefined/null fields).
@propertyWrapper
public struct DefaultFalse: Codable, Hashable, Sendable {
    public var wrappedValue: Bool

    public init(wrappedValue: Bool = false) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = (try? container.decode(Bool.self)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// An array that decodes to `[]` when the key is missing or null.
@propertyWrapper
public struct DefaultEmpty<Element: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var wrappedValue: [Element]

    public init(wrappedValue: [Element] = []) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = []
        } else {
            wrappedValue = try container.decode([Element].self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    public func decode(_ type: DefaultFalse.Type, forKey key: Key) throws -> DefaultFalse {
        try decodeIfPresent(type, forKey: key) ?? DefaultFalse()
    }

    public func decode<Element>(_ type: DefaultEmpty<Element>.Type, forKey key: Key) throws -> DefaultEmpty<Element> {
        try decodeIfPresent(type, forKey: key) ?? DefaultEmpty()
    }
}
