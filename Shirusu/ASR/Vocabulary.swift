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

        var out = ""
        out.reserveCapacity(text.count)
        var word = ""

        func flush() {
            guard !word.isEmpty else { return }
            out += corrections[word.lowercased()] ?? word
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
