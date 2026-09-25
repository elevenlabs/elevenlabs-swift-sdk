import Foundation

/// A conversation language, as the code the server expects (e.g. `"en"`). Any code the agent supports works.
public struct Language: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public static let english: Language = "en"
    public static let japanese: Language = "ja"
    public static let chinese: Language = "zh"
    public static let german: Language = "de"
    public static let hindi: Language = "hi"
    public static let french: Language = "fr"
    public static let korean: Language = "ko"
    public static let portuguese: Language = "pt"
    public static let italian: Language = "it"
    public static let spanish: Language = "es"
    public static let indonesian: Language = "id"
    public static let dutch: Language = "nl"
    public static let turkish: Language = "tr"
    public static let polish: Language = "pl"
    public static let swedish: Language = "sv"
    public static let bulgarian: Language = "bg"
    public static let romanian: Language = "ro"
    public static let arabic: Language = "ar"
    public static let czech: Language = "cs"
    public static let greek: Language = "el"
    public static let finnish: Language = "fi"
    public static let malay: Language = "ms"
    public static let danish: Language = "da"
    public static let tamil: Language = "ta"
    public static let tagalog: Language = "tl"
    public static let ukrainian: Language = "uk"
    public static let russian: Language = "ru"
    public static let hungarian: Language = "hu"
    public static let norwegian: Language = "no"
    public static let vietnamese: Language = "vi"
    public static let latvian: Language = "lv"
    public static let lithuanian: Language = "lt"
    public static let slovenian: Language = "sl"
    public static let slovak: Language = "sk"
    public static let croatian: Language = "hr"
}
