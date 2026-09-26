import Foundation

/// A dynamic variable value: any JSON value, sent with its native type.
public typealias DynamicVariableValue = ConversationConfig.JSONValue

extension ConversationConfig {
    /// Any JSON value, sent with its native type.
    public enum JSONValue: Sendable, Equatable {
        case string(String)
        case number(Double)
        case int(Int)
        case boolean(Bool)
        case array([JSONValue])
        case object([String: JSONValue])
        case null
    }
}

extension ConversationConfig.JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(integerLiteral value: Int) {
        self = .int(value)
    }

    public init(floatLiteral value: Double) {
        self = .number(value)
    }

    public init(booleanLiteral value: Bool) {
        self = .boolean(value)
    }

    public init(arrayLiteral elements: Self...) {
        self = .array(elements)
    }

    public init(dictionaryLiteral elements: (String, Self)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension ConversationConfig.JSONValue {
    var jsonObject: Any {
        switch self {
        case let .string(value): value
        case let .number(value): value
        case let .int(value): value
        case let .boolean(value): value
        case let .array(values): values.map(\.jsonObject)
        case let .object(values): values.mapValues(\.jsonObject)
        case .null: NSNull()
        }
    }
}
