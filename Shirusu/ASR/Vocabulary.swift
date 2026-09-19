import Foundation

/// Words the recogniser gets wrong in a way we can name.
///
/// This started as FluidAudio's CTC rescoring, which biases the decoder toward
/// a term list. Measured on real Portuguese speech that was a disaster: at the
/// shipped thresholds it rewrote "mas" as "Mac", "acho" as "cache", "brincar"
/// as "branch". Tightening fixed the substitutions, but the rescorer only runs
/// on `SlidingWindowAsrManager`, and that path drops words on long audio — 273
/// against `AsrManager`'s 309 on a two-minute recording — and duplicates across
/// window seams.
///
/// So the correction moved here, to the text. It can only do what is written
/// below: replace a whole word that the recogniser is known to produce with the
/// word that was meant. It cannot invent, cannot paraphrase, and cannot touch a
/// word that is not listed. Every entry came from a transcript we measured.
nonisolated enum Vocabulary {
    /// Whatever the user has added, merged over the built-in list.
    ///
    /// Read from an actor-isolated store rather than held here, because this
    /// runs on the transcriber's actor and the list is edited on the main one.
    static var all: [String: String] {
        corrections.merging(CustomVocabulary.shared.entries) { _, user in user }
    }

    /// Misheard form, lowercased, to its correction.
    ///
    /// The rule for adding one: it must be a string the recogniser actually
    /// produced, and it must not be a word of Portuguese. "comite" qualifies —
    /// the real word carries an accent ("comitê") and is not matched here.
    static let corrections: [String: String] = [
        "comite": "commit",
        "comit": "commit",
        "ciruzul": "Shirusu",
        "siruzu": "Shirusu",
        "shirousu": "Shirusu",
        "parakeed": "Parakeet",
    ]

    /// Rewrites only whole words, leaving punctuation and spacing alone.
    static func corrected(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // Snapshotted once per call: the map can be edited while a transcript
        // is being corrected, and swapping tables halfway through a sentence
        // would be a strange way to fail.
        let table = all
        var out = ""
        out.reserveCapacity(text.count)
        var word = ""

        func flush() {
            guard !word.isEmpty else { return }
            out += table[word.lowercased()] ?? word
            word = ""
        }

        for character in text {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else {
                flush()
                out.append(character)
            }
        }
        flush()
        return out
    }
}

/// The entries the user added, kept where both the editor and the transcriber
/// can reach them.
///
/// A lock rather than an actor: `Vocabulary.corrected` runs inside the
/// transcriber's actor on the hot path, and making it `await` for a dictionary
/// that changes twice a month would put a suspension point in the middle of
/// every transcript.
nonisolated final class CustomVocabulary: @unchecked Sendable {
    static let shared = CustomVocabulary()

    private let lock = NSLock()
    private var stored: [String: String]

    private static let key = "customVocabulary"

    private init() {
        stored =
            UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    /// Misheard form, lowercased, to what should be written instead.
    var entries: [String: String] {
        lock.withLock { stored }
    }

    func replace(with entries: [String: String]) {
        let cleaned = Dictionary(
            entries
                .map { (key: $0.key.trimmingCharacters(in: .whitespaces).lowercased(), value: $0.value) }
                .filter { !$0.key.isEmpty && !$0.value.isEmpty },
            uniquingKeysWith: { _, last in last }
        )
        lock.withLock { stored = cleaned }
        UserDefaults.standard.set(cleaned, forKey: Self.key)
    }
}
