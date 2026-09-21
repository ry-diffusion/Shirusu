import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import Shirusu

/// A feed shaped like the microphone: open-ended, delivering 100 ms chunks
/// forever. It never finishes on its own, so `stop()` is the only way out —
/// which is the path a real key release takes, and the one a file feed cannot
/// exercise because it ends by itself.
private struct LiveFeed: AudioFeed {
    let samples: [Float]
    let label = "Test microphone"
    /// `nil` is what makes the session treat this as a live input.
    let duration: TimeInterval? = nil

    func chunks() -> AsyncThrowingStream<AudioChunk, Error> {
        let samples = self.samples
        return AsyncThrowingStream { continuation in
            let task = Task {
                let frames = AudioFormats.chunkFrames
                var offset = 0
                let origin = ContinuousClock.now
                var emitted = 0

                while !Task.isCancelled {
                    // Speech first, then silence, the way an open mic behaves.
                    let slice: ArraySlice<Float>
                    if offset < samples.count {
                        let end = min(offset + frames, samples.count)
                        slice = samples[offset..<end]
                        offset = end
                    } else {
                        slice = ArraySlice(repeating: 0, count: frames)
                    }
                    if let buffer = AudioDecoder.makeBuffer(slice) {
                        continuation.yield(
                            AudioChunk(
                                buffer: buffer,
                                peak: AudioChunk.peakMagnitude(of: buffer),
                                position: Double(emitted * frames) / Double(AudioFormats.sampleRate)
                            ))
                    }
                    emitted += 1
                    let target = Double(emitted * frames) / Double(AudioFormats.sampleRate)
                    let deadline = origin.advanced(by: .seconds(target))
                    if deadline > .now {
                        try? await Task.sleep(until: deadline, clock: .continuous)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The metric the hotkey lives or dies by: from letting go to seeing text.
@MainActor
struct PressAndReleaseTests {
    private final class BundleToken {}

    @Test(
        "Time from release to text on a live feed",
        .enabled(if: ShirusuModel.isInstalled),
        .timeLimit(.minutes(5))
    )
    func releaseLatency() async throws {
        let bundle = Bundle(for: BundleToken.self)
        let models = try await ModelSetup.prepare { _, _ in }
        let session = TranscriptionSession(engine: BatchTranscriber(models: models), profile: .pushToTalk)
        await session.prepare()

        for name in ["speech-tiny", "speech-short"] {
            session.clear()
            let url = try #require(bundle.url(forResource: name, withExtension: "m4a"))
            let decoded = try await AudioDecoder.decode(url)

            session.start(LiveFeed(samples: decoded.samples))
            // Hold for the length of the utterance, then let go.
            try await Task.sleep(for: .seconds(decoded.duration))

            let released = ContinuousClock.now
            session.stop()

            while session.phase != .idle || session.transcript.isEmpty {
                if Self.ms(released) > 20_000 { break }
                try await Task.sleep(for: .milliseconds(5))
            }

            print(
                String(
                    format: "RELEASE [%@] %.1fs held -> text in %.0f ms | %@",
                    name, decoded.duration, Self.ms(released), session.transcript.plainText))
            #expect(!session.transcript.isEmpty)
        }
    }

    private static func ms(_ from: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - from
        return (Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 1000
    }
}
