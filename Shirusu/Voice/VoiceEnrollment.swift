import AVFoundation
import AudioCommon
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

/// Keeps the take at the microphone's own rate, and nothing else.
///
/// There used to be a second buffer converting to 16 kHz as it went, and it
/// could fail silently: a Bluetooth microphone renegotiating its format made
/// every conversion throw, `try?` swallowed it, and the take reached the check
/// with no audio in it while this buffer filled normally. One capture and one
/// resampler cannot disagree like that.
private actor NativeBuffer {
    private(set) var rate: Double = 0
    /// The loudest thing heard. Silence and a misread line need different
    /// advice, and only this tells them apart.
    private(set) var peak: Float = 0
    private var samples: [Float] = []

    func append(_ buffer: AVAudioPCMBuffer, peak chunkPeak: Float) {
        // A format renegotiation hands out buffers with no rate and no frames.
        // Taking the rate from one would leave the take unresampleable, so they
        // are dropped — at 100 ms each, that is cheap.
        guard
            buffer.format.sampleRate > 0,
            buffer.frameLength > 0,
            let channel = buffer.floatChannelData?[0]
        else { return }

        rate = buffer.format.sampleRate
        peak = max(peak, chunkPeak)
        samples.append(
            contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    func reset() {
        samples = []
        rate = 0
        peak = 0
    }

    var seconds: TimeInterval { rate > 0 ? Double(samples.count) / rate : 0 }

    func snapshot() -> (samples: [Float], rate: Double) { (samples, rate) }

    func take() -> (samples: [Float], rate: Double, peak: Float) {
        defer { samples = [] }
        return (samples, rate, peak)
    }
}

/// Records a reference take from the microphone, and listens while it does.
///
/// Listening as it goes is what lets it stop on its own: the line someone was
/// asked to read is known, so the recorder can tell when they have finished
/// reading it rather than making them find the stop button. The cadence is the
/// caption preview's — transcribe, measure what that cost, and never come back
/// round faster than the model can finish.
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

    /// What the transcriber has caught so far. Empty until the first pass lands.
    var heard = ""
    /// Which of the line's tokens have come back, aligned to
    /// `EnrollmentCheck.tokens`. Empty when there is no line to follow.
    var readSoFar: [Bool] = []

    /// The finished take, however it finished.
    private(set) var take: Take?

    /// Long enough that the tokens are not padded, short enough that the tail
    /// is past anything the model reads. See `EnrollmentScript`.
    static let wanted: ClosedRange<TimeInterval> = 6...20

    /// The caption preview's everyday interval. A pass never runs faster than
    /// the model can finish one, so this is a floor rather than a promise.
    private static let listenInterval: Double = 0.6

    /// Below this, nothing reached the microphone at all. A hum floor sits
    /// around 0.002; ordinary speech peaks well above 0.05.
    private static let silence: Float = 0.01

    @ObservationIgnored private let native = NativeBuffer()
    @ObservationIgnored private var feed: MicrophoneFeed?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var listener: Task<Void, Never>?

    var isRecording: Bool { phase == .recording }

    /// The backstop for a recorder that goes away without being told to stop.
    /// The tasks hold the feed, not the other way round, so nothing else would
    /// ever close the microphone.
    deinit {
        pump?.cancel()
        listener?.cancel()
    }

    func start(
        device: InputDevice?,
        script: String?,
        transcriber: BatchTranscriber?
    ) async {
        guard phase != .recording else { return }
        guard await MicrophoneFeed.requestAccess() else {
            phase = .failed(MicrophoneError.accessDenied.localizedDescription)
            return
        }

        await native.reset()
        duration = 0
        level = 0
        heard = ""
        readSoFar = []
        take = nil
        phase = .recording

        let feed = MicrophoneFeed(device: device)
        self.feed = feed
        pump = Task { [weak self, native] in
            do {
                // Away from the main actor, which is where this task runs.
                let stream = await feed.opened()
                for try await chunk in stream {
                    await native.append(chunk.buffer, peak: chunk.peak)
                    let seconds = await native.seconds
                    // Gone, or stopped. This used to check and carry on
                    // regardless, because the check was inside a closure and
                    // could only return from that — so a sheet dismissed
                    // mid-recording left the microphone open, the orange dot
                    // lit, and the take growing for the rest of the session.
                    guard let self, self.phase == .recording else { return }
                    self.level = chunk.peak
                    self.duration = seconds
                    // However well it is going, twenty seconds is past
                    // everything the model reads.
                    if seconds >= Self.wanted.upperBound {
                        Task { await self.finish() }
                    }
                }
            } catch {
                guard let self, self.phase == .recording else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }

        if let transcriber {
            listen(to: script, with: transcriber)
        }
    }

    private func listen(to script: String?, with transcriber: BatchTranscriber) {
        listener = Task { [weak self, native] in
            while !Task.isCancelled {
                // The recorder is gone, or it has stopped. Either way nobody
                // is reading this, and a pass that keeps running keeps the
                // Neural Engine busy for a screen that is no longer there.
                guard let self, self.phase == .recording else { return }

                let started = ContinuousClock.now
                let (raw, rate) = await native.snapshot()

                if let pass = await Self.listenBack(
                    raw, rate: rate, script: script, with: transcriber)
                {
                    guard self.phase == .recording else { return }
                    self.heard = pass.text
                    self.readSoFar = pass.progress?.matched ?? []
                    // The line is done. Waiting for a button press now only
                    // records the silence after it.
                    if let progress = pass.progress,
                        progress.accuracy >= VoiceProfile.Check.passMark
                    {
                        Task { await self.finish() }
                    }
                }

                let elapsed = ContinuousClock.now - started
                let cost = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                try? await Task.sleep(for: .seconds(max(Self.listenInterval, cost)))
            }
        }
    }

    /// One pass over the take so far, off the main actor.
    ///
    /// `nonisolated` is doing real work here: this task runs on the main actor
    /// because that is where it was started, and resampling twenty seconds of
    /// 48 kHz audio before decoding it is not something to do there. A
    /// `nonisolated async` function runs on the generic executor instead.
    ///
    /// Returns nothing while there is less audio than the decoder will accept.
    private nonisolated static func listenBack(
        _ raw: [Float],
        rate: Double,
        script: String?,
        with transcriber: BatchTranscriber
    ) async -> (text: String, progress: EnrollmentCheck.Progress?)? {
        let samples = atRecogniserRate(raw, from: rate)
        guard samples.count >= BatchTranscriber.minimumSamples else { return nil }
        let text = (try? await transcriber.transcribe(samples)) ?? ""
        return (text, script.map { EnrollmentCheck.progress(script: $0, heard: text) })
    }

    /// Stop, and keep the take as a 24 kHz file plus the 16 kHz the check reads.
    @discardableResult
    func finish() async -> Take? {
        guard phase == .recording else { return nil }
        pump?.cancel()
        listener?.cancel()
        pump = nil
        listener = nil
        feed = nil
        level = 0
        phase = .idle

        let (raw, rate, peak) = await native.take()
        guard !raw.isEmpty, rate > 0 else {
            phase = .failed(MicrophoneError.noInputDevice.localizedDescription)
            return nil
        }

        let reference = Int(rate) == AudioFormats.referenceSampleRate
            ? raw
            : AudioFileLoader.resample(
                raw, from: Int(rate), to: AudioFormats.referenceSampleRate, quality: .mastering)

        let url = FileManager.default.temporaryDirectory
            .appending(path: "shirusu-take-\(UUID().uuidString).wav")
        do {
            try WavEncoder
                .data(samples: reference, sampleRate: AudioFormats.referenceSampleRate)
                .write(to: url)
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }

        let finished = Take(
            url: url,
            heardSamples: Self.atRecogniserRate(raw, from: rate),
            duration: Double(reference.count) / Double(AudioFormats.referenceSampleRate),
            wasSilent: peak < Self.silence)
        take = finished
        return finished
    }

    func cancel() {
        pump?.cancel()
        listener?.cancel()
        pump = nil
        listener = nil
        feed = nil
        level = 0
        duration = 0
        heard = ""
        readSoFar = []
        take = nil
        if case .failed = phase { return }
        phase = .idle
    }

    func clearFailure() {
        if case .failed = phase { phase = .idle }
    }

    /// Speech is band-limited and this is a downsample, which is exactly where
    /// `.standard` is meant to be used and mastering-grade filtering is wasted.
    private nonisolated static func atRecogniserRate(
        _ samples: [Float], from rate: Double
    ) -> [Float] {
        guard rate > 0 else { return [] }
        guard Int(rate) != AudioFormats.sampleRate else { return samples }
        return AudioFileLoader.resample(
            samples, from: Int(rate), to: AudioFormats.sampleRate, quality: .standard)
    }

    nonisolated struct Take: Sendable {
        /// 24 kHz on disk, which is what the cloning model conditions on.
        let url: URL
        /// The same take at 16 kHz, for the transcriber.
        let heardSamples: [Float]
        let duration: TimeInterval
        /// Nothing ever reached the microphone. A different problem from a line
        /// read badly, and it needs different advice.
        let wasSilent: Bool
    }
}

/// How much of what someone was asked to read actually came back.
///
/// This is the part that makes recording worth doing here rather than in
/// QuickTime: the app already has a transcriber loaded, so it can listen to the
/// take and say whether it caught the words — which is the difference between
/// "the level meter moved" and "this is usable".
nonisolated enum EnrollmentCheck {
    /// A word of the line as it is shown, beside the form used to match it.
    /// Splitting once keeps what is drawn and what is compared in step.
    nonisolated struct Token: Sendable, Equatable, Identifiable {
        let id: Int
        let display: String
        let folded: String

        /// A lone dash is drawn but never matched, and never counted against
        /// anyone either.
        var isWord: Bool { !folded.isEmpty }
    }

    nonisolated struct Progress: Sendable, Equatable {
        let tokens: [Token]
        /// Aligned to `tokens`. Punctuation is always true: there is nothing
        /// there to hear.
        let matched: [Bool]
        let accuracy: Double
    }

    static func tokens(_ script: String) -> [Token] {
        script
            .split(whereSeparator: \.isWhitespace)
            .enumerated()
            .map { Token(id: $0.offset, display: String($0.element), folded: folded($0.element)) }
    }

    /// Longest common subsequence over folded words, traced back so the screen
    /// can say which ones have landed. Order matters, so a transcript that
    /// catches every word in the wrong places does not pass.
    static func progress(script: String, heard: String) -> Progress {
        let tokens = tokens(script)
        let wanted = tokens.map(\.folded)
        let got = heard
            .split(whereSeparator: \.isWhitespace)
            .map { folded($0) }
            .filter { !$0.isEmpty }

        var matched = tokens.map { !$0.isWord }
        let words = tokens.indices.filter { tokens[$0].isWord }
        guard !words.isEmpty else { return Progress(tokens: tokens, matched: matched, accuracy: 0) }
        guard !got.isEmpty else { return Progress(tokens: tokens, matched: matched, accuracy: 0) }

        // The table is over the real words only, so punctuation cannot shift
        // the alignment underneath the backtrace.
        let script = words.map { wanted[$0] }
        var table = [[Int]](
            repeating: [Int](repeating: 0, count: got.count + 1), count: script.count + 1)
        for i in 1...script.count {
            for j in 1...got.count {
                table[i][j] = script[i - 1] == got[j - 1]
                    ? table[i - 1][j - 1] + 1
                    : max(table[i - 1][j], table[i][j - 1])
            }
        }

        var hits = 0
        var i = script.count
        var j = got.count
        while i > 0, j > 0 {
            if script[i - 1] == got[j - 1] {
                matched[words[i - 1]] = true
                hits += 1
                i -= 1
                j -= 1
            } else if table[i - 1][j] >= table[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return Progress(
            tokens: tokens,
            matched: matched,
            accuracy: Double(hits) / Double(script.count))
    }

    static func accuracy(script: String, heard: String) -> Double {
        progress(script: script, heard: heard).accuracy
    }

    /// Case, accents and punctuation are the transcriber's business, not the
    /// speaker's: someone who read the line correctly should not fail because
    /// the model wrote "voce" or left the comma out.
    private static func folded(_ text: some StringProtocol) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
