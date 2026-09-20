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

/// Keeps the take at the microphone's own rate.
///
/// `UtteranceBuffer` converts to 16 kHz because that is the only rate the
/// recogniser accepts, and a reference built from it can never carry anything
/// above 8 kHz. This keeps the second copy the cloning model wants.
private actor NativeBuffer {
    private(set) var rate: Double = 0
    private var samples: [Float] = []

    /// Channel zero rather than a downmix: a microphone puts its signal there,
    /// and summing an interface's unused second input would only add its noise.
    func append(_ buffer: AVAudioPCMBuffer) {
        rate = buffer.format.sampleRate
        guard let channel = buffer.floatChannelData?[0] else { return }
        samples.append(
            contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    func reset() {
        samples = []
        rate = 0
    }

    func take() -> (samples: [Float], rate: Double) {
        defer { samples = [] }
        return (samples, rate)
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
    /// How much of the line has come back, 0...1. Zero when there is no line.
    var readSoFar: Double = 0

    /// The finished take, however it finished.
    private(set) var take: Take?

    /// Long enough that the tokens are not padded, short enough that the tail
    /// is past anything the model reads. See `EnrollmentScript`.
    static let wanted: ClosedRange<TimeInterval> = 6...20

    /// The caption preview's everyday interval. A pass never runs faster than
    /// the model can finish one, so this is a floor rather than a promise.
    private static let listenInterval: Double = 0.6

    @ObservationIgnored private let buffer = UtteranceBuffer()
    @ObservationIgnored private let native = NativeBuffer()
    @ObservationIgnored private var feed: MicrophoneFeed?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var listener: Task<Void, Never>?

    var isRecording: Bool { phase == .recording }

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

        await buffer.reset(limit: nil)
        await native.reset()
        duration = 0
        level = 0
        heard = ""
        readSoFar = 0
        take = nil
        phase = .recording

        let feed = MicrophoneFeed(device: device)
        self.feed = feed
        pump = Task { [weak self, buffer, native] in
            do {
                for try await chunk in feed.chunks() {
                    await buffer.append(chunk.buffer)
                    await native.append(chunk.buffer)
                    let seconds = await buffer.duration
                    await MainActor.run {
                        guard let self, self.phase == .recording else { return }
                        self.level = chunk.peak
                        self.duration = seconds
                        // However well it is going, twenty seconds is past
                        // everything the model reads.
                        if seconds >= Self.wanted.upperBound {
                            Task { await self.finish() }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.phase == .recording else { return }
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }

        if let transcriber {
            listen(to: script, with: transcriber)
        }
    }

    private func listen(to script: String?, with transcriber: BatchTranscriber) {
        listener = Task { [weak self, buffer] in
            while !Task.isCancelled {
                let started = ContinuousClock.now
                let samples = await buffer.snapshot()

                if samples.count >= BatchTranscriber.minimumSamples {
                    let text = (try? await transcriber.transcribe(samples)) ?? ""
                    let matched = script.map {
                        EnrollmentCheck.accuracy(script: $0, heard: text)
                    } ?? 0

                    await MainActor.run {
                        guard let self, self.phase == .recording else { return }
                        self.heard = text
                        self.readSoFar = matched
                        // The line is done. Waiting for a button press now only
                        // records the silence after it.
                        if script != nil, matched >= VoiceProfile.Check.passMark {
                            Task { await self.finish() }
                        }
                    }
                }

                let elapsed = ContinuousClock.now - started
                let cost = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                try? await Task.sleep(for: .seconds(max(Self.listenInterval, cost)))
            }
        }
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

        let heardSamples = await buffer.take()
        let (raw, rate) = await native.take()
        guard !raw.isEmpty, rate > 0 else { return nil }

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
            heardSamples: heardSamples,
            duration: Double(reference.count) / Double(AudioFormats.referenceSampleRate))
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
        readSoFar = 0
        take = nil
        if case .failed = phase { return }
        phase = .idle
    }

    func clearFailure() {
        if case .failed = phase { phase = .idle }
    }

    nonisolated struct Take: Sendable {
        /// 24 kHz on disk, which is what the cloning model conditions on.
        let url: URL
        /// The same take at 16 kHz, for the transcriber.
        let heardSamples: [Float]
        let duration: TimeInterval
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
