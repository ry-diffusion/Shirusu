import AVFoundation
import FluidAudio
import Foundation
import OSLog

/// Keeps the utterance at 16 kHz so the release pass can re-read it whole.
///
/// The streaming engine converts internally and throws the samples away; this
/// keeps a copy, which costs 64 KB per second of speech.
actor UtteranceBuffer {
    private let converter = AudioConverter()
    private var samples: [Float] = []

    /// Seconds to keep, or `nil` for all of them.
    ///
    /// An utterance keeps everything, because the release pass re-reads it
    /// whole. Live captions cannot: they run for as long as a film, and an
    /// hour of them would be 230 MB of audio nobody will ever ask to see again,
    /// followed by a final pass over that hour at the moment you switch it off.
    private var limit: TimeInterval?

    var duration: TimeInterval { Double(samples.count) / 16_000 }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = try? converter.resampleBuffer(buffer) else { return }
        samples.append(contentsOf: converted)
        trim()
    }

    /// Dropping the head is a copy of everything behind it, so it is worth
    /// doing rarely: let the buffer run `slack` seconds over the limit and cut
    /// back to it in one go, rather than shuffling the whole array every time
    /// another 100 ms of audio lands.
    private func trim() {
        guard let limit else { return }
        let cap = Int(limit * 16_000)
        let slack = Int(Self.slack * 16_000)
        guard samples.count > cap + slack else { return }
        samples.removeFirst(samples.count - cap)
    }

    private static let slack: TimeInterval = 5

    func take() -> [Float] {
        defer { samples = [] }
        return samples
    }

    /// Everything heard so far, without consuming it.
    func snapshot() -> [Float] { samples }

    /// The last `seconds` of it, for a preview that should not get slower the
    /// longer someone speaks.
    func recent(seconds: TimeInterval) -> [Float] {
        let wanted = Int(seconds * 16_000)
        guard samples.count > wanted else { return samples }
        return Array(samples.suffix(wanted))
    }

    func reset(limit: TimeInterval? = nil) {
        samples = []
        self.limit = limit
    }
}

/// The authoritative pass: decodes the whole utterance in one go.
///
/// This is `AsrManager` rather than `SlidingWindowAsrManager` on purpose.
/// The sliding window supports custom vocabulary and this does not, but on real
/// two-minute speech the window produced 273 words where this produced 309, and
/// duplicated text across its seams. Losing words is a worse bargain than
/// losing decoder-level biasing, so the term corrections moved into
/// `Vocabulary` as plain text replacement instead.
actor BatchTranscriber {
    private static let log = Logger(subsystem: "br.com.zesmoi.Shirusu", category: "models")

    private let manager = AsrManager(config: .default)

    /// Where the weights come from, asked again after an idle unload.
    ///
    /// A provider rather than an `AsrModels` handed in once, because that
    /// value *is* the four CoreML models. Anyone keeping one around to reload
    /// from would keep the weights resident and `cleanup()` would free
    /// nothing, which is why nobody outside this actor holds them any more.
    private let acquire: @Sendable () async throws -> AsrModels

    private var isLoaded = false

    /// The load in flight, so that everyone wanting the model waits on one
    /// piece of work rather than starting another.
    ///
    /// Being an actor does not give this for free. `load` suspends on its way
    /// through, and a second call arriving during that suspension found
    /// `isLoaded` still false and loaded the weights all over again. There are
    /// three callers now — the launch warm-up, the preview loop and the
    /// release pass — and a press short enough to end mid-load has all three
    /// in the air at once.
    private var loading: Task<Void, Error>?

    /// Who is decoding right now, and when the last of them stopped.
    private var use = ModelUse()
    /// Wakes once the deadline is due and asks whether it still holds.
    private var sweep: Task<Void, Never>?

    init(acquire: @escaping @Sendable () async throws -> AsrModels) {
        self.acquire = acquire
    }

    /// For tests and one-off passes, where the weights are already in hand and
    /// nothing is trying to give them back.
    init(models: AsrModels) {
        self.init { models }
    }

    /// Idempotent, and safe to call from anywhere at any time.
    func load() async throws {
        if isLoaded { return }
        if let loading { return try await loading.value }

        let task = Task { [acquire, manager] in
            let models = try await acquire()
            try await manager.loadModels(models)
        }
        loading = task
        defer { loading = nil }
        try await task.value
        isLoaded = true
        // Loaded and not yet used has to start the clock as well. The launch
        // warm-up loads without transcribing anything, and a session where
        // nobody then presses the key is exactly the one that should not be
        // holding most of a gigabyte an hour later.
        use.idle()
        restartSweep()
    }

    /// Give the weights back. The next `transcribe` fetches them again.
    ///
    /// `AsrManager.cleanup()` is the whole of it only because the provider
    /// replaced the stored `AsrModels`: with a copy still held somewhere this
    /// would release the manager's references and free nothing.
    func unload() async {
        // Not out from under a run in progress. This is reachable from memory
        // pressure as well as from the deadline, and a warning from the system
        // is not worth the dictation someone is in the middle of — the sweeper
        // collects it seconds later, once the words have landed.
        guard !use.isActive else {
            restartSweep()
            return
        }
        sweep?.cancel()
        sweep = nil
        loading?.cancel()
        loading = nil
        guard isLoaded else { return }
        isLoaded = false
        // A reload builds fresh `MLModel`s, and CoreML specialises the graph
        // for the Neural Engine per instance, so the warm-up launch paid for
        // does not survive this.
        isWarm = false
        use.forget()
        await manager.cleanup()
        Self.log.info("Transcription weights released")
    }

    private func restartSweep() {
        sweep?.cancel()
        sweep = Task {
            try? await Task.sleep(for: ModelIdle.transcription)
            guard !Task.isCancelled else { return }
            await self.unloadIfIdle()
        }
    }

    private func unloadIfIdle() async {
        guard use.hasExpired(after: ModelIdle.transcription) else {
            // Picked up again while the sweeper slept, or still decoding now.
            // Either way the deadline moved; come back for the new one.
            restartSweep()
            return
        }
        await unload()
    }

    /// Shorter than this and the decoder rejects the buffer outright.
    static let minimumSamples = 16_000

    /// Runs one throwaway pass so the first real one does not pay for it.
    ///
    /// Loading the models is not the same as being ready to use them. CoreML
    /// specialises a graph for the Neural Engine on its first prediction, and
    /// without this that cost lands on whoever presses the key first — the one
    /// press where the delay is most likely to be read as the feature being
    /// slow. A second of near-silence goes down the identical path and moves it
    /// to launch, where nobody is waiting.
    ///
    /// Not digital silence: a floor of noise keeps any short-circuit on an
    /// all-zero buffer from skipping the encoder this exists to warm.
    func warmUp() async {
        guard isLoaded, !isWarm else { return }
        isWarm = true
        var samples = [Float](repeating: 0, count: Self.minimumSamples)
        for index in samples.indices { samples[index] = Float.random(in: -0.001...0.001) }
        _ = try? await transcribe(samples)
    }

    private var isWarm = false

    func transcribe(_ samples: [Float]) async throws -> String {
        guard samples.count >= Self.minimumSamples else { return "" }
        // The weights may have been let go of since the last press, and none
        // of the callers is in a position to know that. Loading here is what
        // makes the deadline invisible to everything above.
        try await load()
        use.begin()
        defer {
            use.end()
            restartSweep()
        }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(
            samples, decoderState: &state, language: ShirusuModel.language
        )
        return Vocabulary.corrected(result.text)
    }
}
