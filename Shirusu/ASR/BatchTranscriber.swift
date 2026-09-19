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
    private let manager = AsrManager(config: .default)
    private var isLoaded = false

    /// Idempotent: called at the start of every utterance, loads once.
    func load(_ models: AsrModels) async throws {
        guard !isLoaded else { return }
        try await manager.loadModels(models)
        isLoaded = true
    }

    /// Shorter than this and the decoder rejects the buffer outright.
    static let minimumSamples = 16_000

    func transcribe(_ samples: [Float]) async throws -> String {
        guard samples.count >= Self.minimumSamples else { return "" }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(
            samples, decoderState: &state, language: ShirusuModel.language
        )
        return Vocabulary.corrected(result.text)
    }
}
