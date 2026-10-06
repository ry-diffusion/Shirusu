import FluidAudio
import Foundation
import NaturalLanguage

/// `shirusu transcribe`: a file in, text or timed segments out.
enum TranscribeCommand {
    static func run(_ arguments: Arguments) async throws {
        let format = arguments.value("format") ?? "text"
        guard ["text", "json", "srt", "vtt"].contains(format) else {
            throw Failure("--format is text, json, srt or vtt.", code: 64)
        }
        let languages = try arguments.value("language").map(Language.list)
            ?? LanguagePriorities.shared.ordered

        let file = try StandardInput.file(named: arguments.value("name"))
        defer { try? FileManager.default.removeItem(at: file) }

        Console.note("Reading the audio…")
        let audio = try await AudioDecoder.decode(file)
        guard audio.samples.count >= BatchTranscriber.minimumSamples else {
            throw Failure("Under a second of audio: too short to transcribe.", code: 65)
        }

        let engine = Engines.transcriber()
        Console.note("Transcribing \(Timecode.minutes(audio.duration))…")
        let result = try await engine.transcribeTimed(
            audio.samples, hint: LanguagePriorities.decoderHint(for: languages))
        let transcript = TimedTranscript(result: result, duration: audio.duration)

        switch format {
        case "json": Console.write(try transcript.json())
        case "srt": Console.write(transcript.srt())
        case "vtt": Console.write(transcript.vtt())
        default: Console.print(transcript.text)
        }
    }
}

/// Engines built the way the app builds them, minus the screens.
enum Engines {
    /// The same Parakeet the app runs, from the same folder. Only a Mac that
    /// has never opened the app downloads anything here.
    static func transcriber() -> BatchTranscriber {
        let progress = ProgressLine()
        return BatchTranscriber {
            try await ModelSetup.prepare { step, fraction in
                // A model already on disk still passes through these with
                // nothing to count, which is not worth a line.
                switch step {
                case .downloading(_, 0), .compiling(""): return
                default: break
                }
                // The step names itself on the main actor, as it does for the app.
                Task { @MainActor in progress.show(step.detail, fraction: fraction) }
            }
        }
    }
}

/// Prints a progress line only when it says something new.
nonisolated final class ProgressLine: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""

    func show(_ text: String, fraction: Double? = nil) {
        let line: String
        if let fraction, fraction > 0, fraction < 1 {
            // Tenths are enough to show movement without a line per file.
            line = "\(text) (\(Int(fraction * 10) * 10)%)"
        } else {
            line = text
        }
        let isNew = lock.withLock {
            guard line != last else { return false }
            last = line
            return true
        }
        if isNew { Console.note(line) }
    }
}

/// What was said and when, cut into lines a person could read as a subtitle
/// or a dubber could say in the same breath.
struct TimedTranscript: Codable {
    nonisolated struct Segment: Codable {
        let id: Int
        let start: Double
        let end: Double
        let text: String
    }

    /// The language the whole of it reads as, as an ISO code.
    let language: String?
    let duration: Double
    let text: String
    let segments: [Segment]

    init(result: ASRResult, duration: TimeInterval) {
        let words = buildWordTimings(from: result.tokenTimings ?? [])
        var segments: [Segment] = []
        for line in Self.lines(from: words) {
            let text = Vocabulary.corrected(line.map(\.word).joined(separator: " "))
            segments.append(Segment(
                id: segments.count + 1,
                start: Self.rounded(line.first!.startTime),
                end: Self.rounded(line.last!.endTime),
                text: text))
        }
        self.text = Vocabulary.corrected(result.text)
        self.duration = Self.rounded(duration)
        self.segments = segments
        self.language = Self.language(of: self.text)
    }

    /// A pause this long ends a line whatever the punctuation says.
    private static let pause: TimeInterval = 0.8
    /// Past this, a comma is reason enough to start a new line.
    private static let long: TimeInterval = 7
    /// And past this, any word boundary is.
    private static let tooLong: TimeInterval = 14

    /// Sentences, unless a sentence runs long or the speaker stops mid-way.
    ///
    /// A dub is rewritten one line at a time and has to be said in that
    /// line's time, so a line is the unit worth getting right: a whole
    /// sentence where there is one, and nothing a voice cannot say in a
    /// breath where there is not.
    private static func lines(from words: [WordTiming]) -> [[WordTiming]] {
        var lines: [[WordTiming]] = []
        var current: [WordTiming] = []
        for (index, word) in words.enumerated() {
            current.append(word)
            let next = words.indices.contains(index + 1) ? words[index + 1] : nil
            let length = word.endTime - current[0].startTime
            let gap = next.map { $0.startTime - word.endTime } ?? .infinity
            let last = word.word.last
            let endsSentence = last.map { ".?!…。？！".contains($0) } ?? false
            let endsClause = last.map { ",;:—".contains($0) } ?? false
            if endsSentence || gap >= pause || (endsClause && length >= long) || length >= tooLong {
                lines.append(current)
                current = []
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private static func language(of text: String) -> String? {
        let recogniser = NLLanguageRecognizer()
        recogniser.languageConstraints = LanguagePriorities.supported.map { NLLanguage($0.rawValue) }
        recogniser.processString(text)
        return recogniser.dominantLanguage?.rawValue
    }

    private static func rounded(_ seconds: TimeInterval) -> Double {
        (seconds * 1000).rounded() / 1000
    }

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(contentsOf: "\n".utf8)
        return data
    }

    func srt() -> String {
        segments.map { segment in
            "\(segment.id)\n\(Timecode.srt(segment.start)) --> \(Timecode.srt(segment.end))\n\(segment.text)\n"
        }
        .joined(separator: "\n")
    }

    func vtt() -> String {
        "WEBVTT\n\n" + segments.map { segment in
            "\(Timecode.vtt(segment.start)) --> \(Timecode.vtt(segment.end))\n\(segment.text)\n"
        }
        .joined(separator: "\n")
    }
}

enum Timecode {
    static func srt(_ seconds: Double) -> String { format(seconds, separator: ",") }
    static func vtt(_ seconds: Double) -> String { format(seconds, separator: ".") }

    private static func format(_ seconds: Double, separator: String) -> String {
        let millis = Int((max(0, seconds) * 1000).rounded())
        let hours = millis / 3_600_000
        let minutes = millis / 60_000 % 60
        let secs = millis / 1000 % 60
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, separator, millis % 1000)
    }

    /// "2 min 05 s", for a progress line.
    static func minutes(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? "\(total) s" : String(format: "%d min %02d s", total / 60, total % 60)
    }
}
