import AVFoundation
import Foundation
import Observation

/// What to read while a voice is being recorded.
///
/// The lines are built around what the model actually reads. `ChatterboxTTSModel`
/// conditions its prompt mel on the first ten seconds and its speech tokens on
/// the first six, so a line that runs much past ten seconds is mostly wasted and
/// one under six leaves the tokens padded. Each of these lands between six and
/// nine seconds at an unhurried pace.
///
/// They are sentences rather than a phoneme list on purpose: coverage that does
/// not sound like someone talking produces a reference in "reading a list"
/// voice, and the model copies delivery along with timbre. Within that, they
/// reach for the sounds a short neutral sentence usually misses — in Portuguese
/// the nasals, `lh`, `nh` and the tapped and guttural r; in English the two
/// `th`s, `/dʒ/` and `/ʃ/`.
///
/// They are deliberately not localizable. A line is content for one language,
/// picked by `language`, so running it through the catalog would invite a
/// translator to render the English script in Portuguese and break the English
/// enrollment — the opposite of what a translation is for.
nonisolated enum EnrollmentScript {
    static func lines(for language: SpeechSession.Language) -> [String] {
        switch language {
        case .portuguese:
            [
                "Hoje de manhã choveu forte, mas agora o céu está limpo e dá pra ver a serra lá longe.",
                "Minha irmã trouxe pão quente e um queijo velho que ela guardava havia meses.",
                "O trabalho do relojoeiro exige calma: cada engrenagem precisa ficar no seu lugar certo.",
                "Se ninguém reclamar, amanhã cedo a gente atravessa a ponte e almoça do outro lado do rio.",
            ]
        case .english:
            [
                "The weather turned just after lunch, so we walked the long way home and talked about nothing.",
                "She judged the bridge unsafe, which surprised everyone who had crossed it that morning.",
                "Thursday brought hail in June, of all things, and the whole street came out to watch.",
                "I would rather wait another thirty minutes than squeeze onto that bus with six shopping bags.",
            ]
        default:
            // Writing a phonetically considered script takes a speaker of the
            // language. Offering a bad one in six more languages would be worse
            // than offering none: people would read it, and the reference would
            // carry whatever the guesswork got wrong.
            []
        }
    }
}

/// Records a reference take from the microphone.
///
/// It reuses `UtteranceBuffer`, which is already the app's answer to "keep this
/// speech at 16 kHz", so a recording and a dictation are the same samples in
/// the same shape — which is what lets the transcriber check one of them.
@MainActor
@Observable
final class VoiceRecorder {
    enum Phase: Equatable {
        case idle
        case recording
        case failed(String)
    }

    var phase: Phase = .idle
    var level: Float = 0
    var duration: TimeInterval = 0

    /// Long enough that the tokens are not padded, short enough that the tail
    /// is past anything the model reads. See `EnrollmentScript`.
    static let wanted: ClosedRange<TimeInterval> = 6...20

    @ObservationIgnored private let buffer = UtteranceBuffer()
    @ObservationIgnored private var feed: MicrophoneFeed?
    @ObservationIgnored private var pump: Task<Void, Never>?

    var isRecording: Bool { phase == .recording }

    func start(device: InputDevice?) async {
        guard phase != .recording else { return }
        guard await MicrophoneFeed.requestAccess() else {
            phase = .failed(MicrophoneError.accessDenied.localizedDescription)
            return
        }

        await buffer.reset(limit: nil)
        duration = 0
        level = 0
        phase = .recording

        let feed = MicrophoneFeed(device: device)
        self.feed = feed
        pump = Task { [weak self, buffer] in
            do {
                for try await chunk in feed.chunks() {
                    await buffer.append(chunk.buffer)
                    let seconds = await buffer.duration
                    await MainActor.run {
                        guard let self, self.phase == .recording else { return }
                        self.level = chunk.peak
                        self.duration = seconds
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.phase == .recording else { return }
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Stop, and hand back the take as samples plus a file the decoder can read.
    ///
    /// The file lands in the temporary directory: whether it is worth keeping is
    /// the profile store's decision, and it moves it out if so.
    @discardableResult
    func finish() async -> Take? {
        guard phase == .recording else { return nil }
        pump?.cancel()
        pump = nil
        feed = nil
        level = 0
        phase = .idle

        let samples = await buffer.take()
        guard !samples.isEmpty else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appending(path: "shirusu-take-\(UUID().uuidString).wav")
        do {
            try WavEncoder.data(samples: samples, sampleRate: AudioFormats.sampleRate).write(to: url)
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }
        return Take(url: url, samples: samples)
    }

    func cancel() {
        pump?.cancel()
        pump = nil
        feed = nil
        level = 0
        duration = 0
        if case .failed = phase { return }
        phase = .idle
    }

    func clearFailure() {
        if case .failed = phase { phase = .idle }
    }

    nonisolated struct Take: Sendable {
        let url: URL
        let samples: [Float]

        var duration: TimeInterval { Double(samples.count) / Double(AudioFormats.sampleRate) }
    }
}

/// How much of what someone was asked to read actually came back.
///
/// This is the part that makes recording worth doing here rather than in
/// QuickTime: the app already has a transcriber loaded, so it can listen to the
/// take and say whether it caught the words — which is the difference between
/// "the level meter moved" and "this is usable".
nonisolated enum EnrollmentCheck {
    /// Longest common subsequence over normalised words, as a fraction of the
    /// script. Order matters, so a transcript that catches every word in the
    /// wrong places does not pass.
    static func accuracy(script: String, heard: String) -> Double {
        let wanted = words(script)
        let got = words(heard)
        guard !wanted.isEmpty else { return 0 }

        var previous = [Int](repeating: 0, count: got.count + 1)
        var current = previous
        for i in 1...wanted.count {
            for j in 1...max(got.count, 1) where !got.isEmpty {
                current[j] = wanted[i - 1] == got[j - 1]
                    ? previous[j - 1] + 1
                    : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
            current = [Int](repeating: 0, count: got.count + 1)
        }
        return Double(previous[got.count]) / Double(wanted.count)
    }

    /// Case, accents and punctuation are the transcriber's business, not the
    /// speaker's: someone who read the line correctly should not fail because
    /// the model wrote "voce" or left the comma out.
    private static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
