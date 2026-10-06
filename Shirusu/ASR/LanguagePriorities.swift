import FluidAudio
import Foundation

/// The languages someone speaks, the one they speak most first.
///
/// Parakeet works out the language by itself, utterance by utterance. There is
/// no switch that makes it write Portuguese; what it takes is a hint, and the
/// hint is narrower than its name. FluidAudio uses it to filter candidate
/// tokens by writing system — Latin, Cyrillic, Greek — and, for French alone,
/// to keep English-only words out. This list is where that hint now comes
/// from. It used to be a hard-coded Portuguese, which was harmless for anyone
/// writing in the Latin alphabet and quietly forced Russian, Ukrainian,
/// Bulgarian and Greek into it.
///
/// It is deliberately not handed to `NLLanguageRecognizer` as hints. Measured,
/// those are not a gentle prior: with Portuguese and English hinted, "Hola a
/// todos, gracias por venir" came back as Portuguese, while with no hints at
/// all every mixed Portuguese-and-English sentence tried was still recognised
/// as Portuguese. The rewrite would have been told to answer a Spanish
/// dictation in Portuguese.
///
/// A lock rather than an actor, for the same reason as `CustomVocabulary`: the
/// transcriber reads this on its hot path and the list changes rarely.
nonisolated final class LanguagePriorities: @unchecked Sendable {
    static let shared = LanguagePriorities()

    /// What Parakeet v3 was trained on. FluidAudio's enum carries a few more
    /// for other models; offering those here would be a promise this one
    /// cannot keep.
    static let supported: [Language] = [
        .bulgarian, .croatian, .czech, .danish, .dutch, .english, .estonian,
        .finnish, .french, .german, .greek, .hungarian, .italian, .latvian,
        .lithuanian, .maltese, .polish, .portuguese, .romanian, .slovak,
        .slovenian, .spanish, .swedish, .russian, .ukrainian,
    ]

    private let lock = NSLock()
    private var stored: [Language]

    private static let key = "dictationLanguages"

    private init() {
        if let codes = UserDefaults.standard.stringArray(forKey: Self.key) {
            stored = Self.cleaned(codes.compactMap(Language.init(rawValue:)))
        } else {
            stored = Self.fromSystem
        }
    }

    /// Most-spoken first. Empty means no preference at all.
    var ordered: [Language] {
        lock.withLock { stored }
    }

    func replace(with languages: [Language]) {
        let cleaned = Self.cleaned(languages)
        lock.withLock { stored = cleaned }
        UserDefaults.standard.set(cleaned.map(\.rawValue), forKey: Self.key)
    }

    /// The hint for the decoder, or `nil` to let it pick freely.
    ///
    /// Only when every language listed shares one alphabet. Someone who speaks
    /// Russian and English needs both scripts, and enforcing either one would
    /// garble the other, so mixing them turns the filter off.
    ///
    /// French is the one language the hint does more for: it also drops a
    /// list of English-only words. That is right for someone who speaks only
    /// French and wrong for someone who also speaks English, so with English on
    /// the list the hint asks for the Latin script and nothing else.
    var decoderHint: Language? {
        Self.decoderHint(for: ordered)
    }

    static func decoderHint(for languages: [Language]) -> Language? {
        guard let first = languages.first else { return nil }
        guard Set(languages.map(\.script)).count == 1 else { return nil }
        if first == .french, languages.contains(.english) { return .english }
        return first
    }

    /// Whether the hint will also keep English-only words out of French.
    static func filtersEnglish(for languages: [Language]) -> Bool {
        decoderHint(for: languages) == .french
    }

    /// The language as it would be written in a list of languages.
    static func name(of language: Language) -> String {
        Locale.current.localizedString(forLanguageCode: language.rawValue)?
            .localizedCapitalized ?? language.rawValue
    }

    /// A first guess for someone who has never opened the setting: the
    /// languages macOS is set to, in that order, that Parakeet can hear.
    private static var fromSystem: [Language] {
        let guessed = cleaned(
            Locale.preferredLanguages.compactMap { identifier in
                Locale(identifier: identifier).language.languageCode
                    .flatMap { Language(rawValue: $0.identifier) }
            })
        // The old behaviour, for a Mac set to none of them: the Latin script.
        return guessed.isEmpty ? [.english] : guessed
    }

    /// Supported, and each one once.
    private static func cleaned(_ languages: [Language]) -> [Language] {
        var seen = Set<Language>()
        return languages.filter { supported.contains($0) && seen.insert($0).inserted }
    }
}
