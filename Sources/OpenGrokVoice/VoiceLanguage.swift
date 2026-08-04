import Foundation

public struct SttLanguage: Codable, Equatable, Sendable {
    public let code: String
    public let name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

public let STT_LANGUAGE_AUTO = "auto"
public let STT_LANGUAGE_DEFAULT = "en"

public let STT_LANGUAGES: [SttLanguage] = [
    SttLanguage(code: "ar", name: "Arabic"),
    SttLanguage(code: "cs", name: "Czech"),
    SttLanguage(code: "da", name: "Danish"),
    SttLanguage(code: "nl", name: "Dutch"),
    SttLanguage(code: "en", name: "English"),
    SttLanguage(code: "fil", name: "Filipino"),
    SttLanguage(code: "fr", name: "French"),
    SttLanguage(code: "de", name: "German"),
    SttLanguage(code: "hi", name: "Hindi"),
    SttLanguage(code: "id", name: "Indonesian"),
    SttLanguage(code: "it", name: "Italian"),
    SttLanguage(code: "ja", name: "Japanese"),
    SttLanguage(code: "ko", name: "Korean"),
    SttLanguage(code: "mk", name: "Macedonian"),
    SttLanguage(code: "ms", name: "Malay"),
    SttLanguage(code: "fa", name: "Persian"),
    SttLanguage(code: "pl", name: "Polish"),
    SttLanguage(code: "pt", name: "Portuguese"),
    SttLanguage(code: "ro", name: "Romanian"),
    SttLanguage(code: "ru", name: "Russian"),
    SttLanguage(code: "es", name: "Spanish"),
    SttLanguage(code: "sv", name: "Swedish"),
    SttLanguage(code: "th", name: "Thai"),
    SttLanguage(code: "tr", name: "Turkish"),
    SttLanguage(code: "vi", name: "Vietnamese")
]

public func sttLanguageByCode(_ code: String) -> SttLanguage? {
    STT_LANGUAGES.first { $0.code == code }
}

public func canonicalizeSttLanguage(_ value: String?) -> String {
    let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if raw.isEmpty { return STT_LANGUAGE_DEFAULT }
    if raw.caseInsensitiveCompare(STT_LANGUAGE_AUTO) == .orderedSame { return STT_LANGUAGE_AUTO }
    if let code = matchingLanguageCode(raw) { return code }
    let primary = raw.split { $0 == "_" || $0 == "-" || $0 == "." }.first.map(String.init) ?? ""
    if let code = matchingLanguageCode(primary) { return code }
    if primary.caseInsensitiveCompare("tl") == .orderedSame { return "fil" }
    return STT_LANGUAGE_DEFAULT
}

public func languageForAPI(_ stored: String) -> String {
    let canonical = canonicalizeSttLanguage(stored)
    guard canonical == STT_LANGUAGE_AUTO else { return canonical }
    let environment = ProcessInfo.processInfo.environment
    for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
        guard let locale = environment[key], !locale.isEmpty else { continue }
        if locale.caseInsensitiveCompare("C") == .orderedSame || locale.caseInsensitiveCompare("POSIX") == .orderedSame {
            continue
        }
        let primary = locale.split { $0 == "_" || $0 == "-" || $0 == "." }.first.map(String.init) ?? ""
        if let code = matchingLanguageCode(primary) { return code }
        if primary.caseInsensitiveCompare("tl") == .orderedSame { return "fil" }
    }
    return STT_LANGUAGE_DEFAULT
}

private func matchingLanguageCode(_ value: String) -> String? {
    STT_LANGUAGES.first {
        $0.code.caseInsensitiveCompare(value) == .orderedSame
    }?.code
}
