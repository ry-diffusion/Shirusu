import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import Shirusu

/// Tests an idea worth taking seriously: skip streaming entirely and just
/// re-transcribe the whole utterance, over and over, while it is being spoken.
///
/// Batch runs at 160–220x realtime, so a five-second utterance costs about
/// 30 ms to decode in full. If that is cheap enough to repeat every 120 ms, the
/// preview stops being a different, worse transcript and becomes the same one —
/// punctuated, unfragmented, identical to what gets inserted.
///
/// The cost is quadratic: every pass re-reads everything said so far. This
/// measures where that stops being free.
@MainActor
struct RepeatedBatchTests {
    nonisolated private static var clip: URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("realaudio/real1.opus")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test(
        "Re-transcribing the whole buffer as it grows",
        .enabled(if: RepeatedBatchTests.clip != nil && ShirusuModel.isInstalled),
        .timeLimit(.minutes(20))
    )
    func repeatedFullPasses() async throws {
        let url = try #require(Self.clip)
        let all = try await AudioDecoder.decode(url).samples

        let models = try await ModelSetup.prepare { _, _ in }
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        let layers = await asr.decoderLayerCount

        let interval = 0.12
        var buffer: [Float] = []
        var offset = 0
        let frames = AudioFormats.chunkFrames
        let origin = ContinuousClock.now
        var lastPass = ContinuousClock.now
        var firstWordAt = -1.0
        var passes: [(audio: Double, cost: Double)] = []
        var latest = ""

        while offset < all.count {
            let end = min(offset + frames, all.count)
            buffer.append(contentsOf: all[offset..<end])
            offset = end

            // Keep pace with the clock, as a live microphone would.
            let target = Double(offset) / Double(AudioFormats.sampleRate)
            let deadline = origin.advanced(by: .seconds(target))
            if deadline > .now { try? await Task.sleep(until: deadline, clock: .continuous) }

            // The decoder rejects anything shorter than about a second, so
            // the first pass cannot happen the instant recording starts.
            guard buffer.count >= AudioFormats.sampleRate else { continue }
            guard Self.since(lastPass) > interval else { continue }
            lastPass = .now

            let started = ContinuousClock.now
            var state = TdtDecoderState.make(decoderLayers: layers)
            latest = try await asr.transcribe(buffer, decoderState: &state).text
            let cost = Self.since(started)
            passes.append((Double(buffer.count) / Double(AudioFormats.sampleRate), cost))

            if firstWordAt < 0, !latest.isEmpty { firstWordAt = Self.since(origin) }
        }

        // How the cost grows as the utterance does.
        for seconds in [5.0, 10.0, 20.0, 30.0, 45.0] {
            guard let nearest = passes.min(by: {
                abs($0.audio - seconds) < abs($1.audio - seconds)
            }), abs(nearest.audio - seconds) < 2 else { continue }
            print(
                String(
                    format: "BATCHLOOP at %4.0fs of audio: one full pass = %5.0f ms",
                    nearest.audio, nearest.cost * 1000))
        }
        print(
            String(
                format: "BATCHLOOP first text %.2fs | %d passes | text: %@",
                firstWordAt, passes.count, latest.prefix(150) as NSString))
        #expect(!latest.isEmpty)
    }

    private static func since(_ from: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - from
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
