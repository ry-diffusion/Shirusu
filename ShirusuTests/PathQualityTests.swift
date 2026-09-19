import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import Shirusu

/// The authoritative pass moved from `AsrManager` to `SlidingWindowAsrManager`
/// purely to gain custom vocabulary. This measures what that cost, because the
/// two do not stitch long audio the same way.
@MainActor
struct PathQualityTests {
    nonisolated private static var realClips: [URL] {
        (1...3)
            .map {
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("realaudio/real\($0).opus")
            }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    @Test(
        "AsrManager versus SlidingWindow on real speech",
        .enabled(if: !PathQualityTests.realClips.isEmpty && ShirusuModel.isInstalled),
        .timeLimit(.minutes(30))
    )
    func comparePaths() async throws {
        let models = try await ModelSetup.prepare { _, _ in }
        let plain = AsrManager(config: .default)
        try await plain.loadModels(models)

        for url in Self.realClips {
            let name = url.deletingPathExtension().lastPathComponent
            let samples = try await AudioDecoder.decode(url).samples

            var state = TdtDecoderState.make(decoderLayers: await plain.decoderLayerCount)
            let batch = try await plain.transcribe(samples, decoderState: &state).text

            let window = SlidingWindowAsrManager(config: .default)
            try await window.loadModels(models)
            try await window.startStreaming(source: .system)
            if let buffer = AudioDecoder.makeBuffer(samples[...]) {
                await window.streamAudio(buffer)
            }
            let windowed = try await window.finish()
            await window.cleanup()

            print("PATH\t\(name)\tAsrManager\t\(batch.split(separator: " ").joined(separator: " "))")
            print("PATH\t\(name)\tSlidingWindow\t\(windowed.split(separator: " ").joined(separator: " "))")
        }
    }
}
