import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import Shirusu

/// The comparison that counts: real human speech, not the `say` fixtures.
///
/// The files are staged into the app container by hand and are not part of the
/// repository — they are someone's actual voice messages. The test skips itself
/// when they are absent.
@MainActor
struct RealAudioComparison {
    nonisolated private static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("realaudio")
    }

    nonisolated private static var clips: [URL] {
        (1...3)
            .map { directory.appendingPathComponent("real\($0).opus") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    @Test(
        "Real Portuguese speech across engines",
        .enabled(if: !RealAudioComparison.clips.isEmpty && ShirusuModel.isInstalled),
        .timeLimit(.minutes(60))
    )
    func compare() async throws {
        var decoded: [(name: String, audio: DecodedAudio)] = []
        for url in Self.clips {
            decoded.append(
                (url.deletingPathExtension().lastPathComponent, try await AudioDecoder.decode(url))
            )
        }
        for (name, audio) in decoded {
            print(String(format: "REAL %@: %.1fs", name, audio.duration))
        }

        func report(_ engine: String, _ clip: String, _ audio: DecodedAudio, _ secs: Double, _ text: String) {
            // One line per result: the engines log while they work, and an
            // interleaved log line would corrupt a multi-line block.
            let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            print(String(format: "RESULT\t%@\t%@\t%.2f\t%@", engine, clip, secs, flat))
        }

        let models = try await ModelSetup.prepare { _, _ in }

        // Parakeet without the custom vocabulary.
        let plain = AsrManager(config: .default)
        try await plain.loadModels(models)
        for (name, audio) in decoded {
            var state = TdtDecoderState.make(decoderLayers: await plain.decoderLayerCount)
            let t = ContinuousClock.now
            let text = try await plain.transcribe(audio.samples, decoderState: &state).text
            report("Parakeet raw", name, audio, Self.since(t), text)
        }

        // Parakeet with it — what ships.
        let batch = BatchTranscriber(models: models)
        try await batch.load()
        _ = try await batch.transcribe(decoded[0].audio.samples)  // warm
        for (name, audio) in decoded {
            let t = ContinuousClock.now
            let text = try await batch.transcribe(audio.samples)
            report("Parakeet + vocab", name, audio, Self.since(t), text)
        }
    }

    private static func since(_ from: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - from
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
