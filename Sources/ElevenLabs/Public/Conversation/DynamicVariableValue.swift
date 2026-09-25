import Foundation

/// A typed value for ElevenAgents dynamic variables.
///
/// Serialized as a native JSON primitive so workflow comparisons
/// (`user_id > 10000`, `is_premium == true`) receive the correct type.
public enum DynamicVariableValue: Sendable, Hashable, Encodable {
    case string(String)
    case number(Double)
    case int(Int)
    case boolean(Bool)

    /// Maps a string-only dictionary to typed dynamic variables.
    public static func dictionary(from stringValues: [String: String]) -> [String: DynamicVariableValue] {
        stringValues.mapValues { .string($0) }
    }

    /// Native JSON primitive for `JSONSerialization`.
    var jsonValue: Any {
        switch self {
        case let .string(value): value
        case let .number(value): value
        case let .int(value): value
        case let .boolean(value): value
        }
    }

    /// Converts typed dynamic variables to a JSON object of native primitives.
    static func jsonObject(from variables: [String: DynamicVariableValue]) -> [String: Any] {
        variables.mapValues(\.jsonValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .boolean(value):
            try container.encode(value)
        }
    }
}

extension DynamicVariableValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension DynamicVariableValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension DynamicVariableValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension DynamicVariableValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .boolean(value)
    }
}

extension Dictionary where Key == String, Value == DynamicVariableValue {
    /// Creates typed dynamic variables from a string-only map.
    public init(_ stringValues: [String: String]) {
        self = DynamicVariableValue.dictionary(from: stringValues)
    }
}
