import Foundation
import Observation

/// The transcript as the UI needs it: one flow of words, each knowing whether
/// the engine has committed to it yet.
///
/// Words are kept as separate values rather than one string so the view can give
/// each one its own identity, and therefore its own entrance. A word that has not
/// changed keeps its identity and does not re-animate.
@MainActor
@Observable
final class Transcript {
    struct Word: Identifiable, Equatable {
        let id: Int
        let text: String
        /// `false` while the engine may still revise this word.
        var isSettled: Bool
    }

    private(set) var words: [Word] = []
    /// True once the head has been dropped to bound memory.
    private(set) var isTruncated = false

    private var nextID = 0

    /// About forty minutes of speech. Past that the head is dropped: it is far
    /// out of view, and an unbounded view tree is not worth the scrollback.
    private let maxWords = 6_000

    var isEmpty: Bool { words.isEmpty }
    var plainText: String { words.map(\.text).joined(separator: " ") }

    func reset() {
        words = []
        nextID = 0
        isTruncated = false
    }

    /// Reconciles against the engine's latest view of the transcript.
    ///
    /// What arrives is not an append. The preview re-reads the last twelve
    /// seconds every pass, so as soon as someone talks for longer than that the
    /// text arrives with its *front* already gone — and on release the whole
    /// utterance arrives at once, with a front that was never shown. Diffing
    /// from index zero, as this used to, meant the first word differed on every
    /// pass, every identity was reassigned, and the entire line re-animated
    /// several times a second. That was the caption's shake.
    ///
    /// So find where the new text sits against the old one first, and diff from
    /// there. Identity survives for as long as a word's text does; the first
    /// word that differs and everything after it get fresh identities, which is
    /// the honest reading, because the engine just revised them.
    func apply(confirmed: String, volatile: String) {
        var incoming: [(text: String, settled: Bool)] = []
        incoming.reserveCapacity(words.count + 16)
        for word in confirmed.split(whereSeparator: \.isWhitespace) {
            incoming.append((String(word), true))
        }
        for word in volatile.split(whereSeparator: \.isWhitespace) {
            incoming.append((String(word), false))
        }

        guard !incoming.isEmpty else {
            words = []
            return
        }

        let overlap = Self.overlap(of: incoming, with: words)

        var rebuilt: [Word] = []
        rebuilt.reserveCapacity(incoming.count)
        for (offset, item) in incoming.enumerated() {
            let reusable = offset >= overlap.incoming && offset < overlap.incoming + overlap.length
            if reusable {
                var word = words[overlap.existing + offset - overlap.incoming]
                word.isSettled = item.settled
                rebuilt.append(word)
            } else {
                rebuilt.append(Word(id: nextID, text: item.text, isSettled: item.settled))
                nextID += 1
            }
        }

        if rebuilt.count > maxWords {
            rebuilt.removeFirst(rebuilt.count - maxWords)
            isTruncated = true
        }

        words = rebuilt
    }

    /// What a one-line caption should show: the most recent text that fits in
    /// `budget` characters, cut at punctuation.
    ///
    /// The model punctuates Portuguese properly, commas included, so its marks
    /// are the best cut points available — far better than a word count, which
    /// lands mid-thought. Three rules, in order:
    ///
    /// 1. Start after the last full stop. This is the one boundary the engine
    ///    never reaches back across, so it holds still while everything after
    ///    it is still being revised, and it is the only thing that ever makes
    ///    the line shorter — which is what lets the caption shrink back down
    ///    instead of creeping wider all session.
    /// 2. Twelve seconds of real speech is often one long sentence, so if that
    ///    does not fit, move the cut forward to the last comma, semicolon or
    ///    colon that does. The result is a whole clause rather than a fragment.
    /// 3. A clause with no punctuation in it at all still has to fit, so drop
    ///    words off the front until it does. The newest words are the ones
    ///    worth reading.
    func caption(budget: Int) -> [Word] {
        guard !words.isEmpty else { return [] }

        // The final word usually ends a sentence itself, and cutting there
        // would leave the caption blank.
        let candidates = words.indices.dropLast()

        var start = words.startIndex
        for index in candidates.reversed() where words[index].closesSentence {
            start = words.index(after: index)
            break
        }

        if length(from: start) > budget {
            // Earliest boundary that fits, so the caption keeps as much of the
            // clause as it can rather than jumping to the last three words.
            for index in candidates[start...] where words[index].closesClause {
                let next = words.index(after: index)
                if length(from: next) <= budget {
                    start = next
                    break
                }
            }
        }

        while start < words.index(before: words.endIndex), length(from: start) > budget {
            start = words.index(after: start)
        }

        return Array(words[start...])
    }

    /// Characters the caption would draw from `start` on, spaces included.
    private func length(from start: Int) -> Int {
        guard start < words.count else { return 0 }
        let text = words[start...].reduce(0) { $0 + $1.text.count }
        return text + (words.count - start - 1)
    }

    /// The longest run of words the two versions agree on, and where it starts
    /// on each side.
    ///
    /// Only one of the two offsets is ever non-zero, because there are only two
    /// ways the versions can be out of step: the preview window has moved on and
    /// the old text has words in front that the new one dropped, or the release
    /// pass brought the whole utterance and the *new* text has words in front
    /// that were never on screen. One start per direction covers both.
    private static func overlap(
        of incoming: [(text: String, settled: Bool)],
        with words: [Word]
    ) -> (existing: Int, incoming: Int, length: Int) {
        var best = (existing: 0, incoming: 0, length: 0)
        guard !words.isEmpty, !incoming.isEmpty else { return best }

        for start in words.indices {
            // Nothing left here could beat what we already have.
            if words.count - start <= best.length { break }
            let run = matching(words, from: start, incoming, from: 0)
            if run > best.length { best = (start, 0, run) }
        }
        for start in incoming.indices.dropFirst() {
            if incoming.count - start <= best.length { break }
            let run = matching(words, from: 0, incoming, from: start)
            if run > best.length { best = (0, start, run) }
        }
        return best
    }

    private static func matching(
        _ words: [Word], from wordStart: Int,
        _ incoming: [(text: String, settled: Bool)], from incomingStart: Int
    ) -> Int {
        var run = 0
        while wordStart + run < words.count,
            incomingStart + run < incoming.count,
            words[wordStart + run].text == incoming[incomingStart + run].text
        {
            run += 1
        }
        return run
    }
}

extension Transcript.Word {
    /// Ends a sentence, allowing for a closing quote or bracket after the stop.
    var closesSentence: Bool {
        guard let last = text.reversed().first(where: { !"\"')]»”’".contains($0) }) else {
            return false
        }
        return ".!?…".contains(last)
    }

    /// Ends a clause: a sentence boundary, or one of the marks the model uses
    /// inside a sentence.
    var closesClause: Bool {
        guard let last = text.reversed().first(where: { !"\"')]»”’".contains($0) }) else {
            return false
        }
        return ".!?…,;:".contains(last)
    }
}
