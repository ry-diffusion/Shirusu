import AVFoundation
import Foundation

/// Replays a decoded file through the same path the microphone uses, so the
/// realtime pipeline is what actually gets exercised when testing with a file.
nonisolated struct FileFeed: AudioFeed {
    /// How fast the file is pushed into the recogniser.
    enum Pace: Hashable, CaseIterable {
        /// One second of audio per second, the way the microphone would deliver it.
        case realtime
        /// As fast as the recogniser accepts it. Still streaming, just not waiting.
        case fast

        var multiplier: Double {
            switch self {
            case .realtime: return 1
            case .fast: return 0
            }
        }
    }

    let audio: DecodedAudio
    let label: String
    let pace: Pace

    var duration: TimeInterval? { audio.duration }

    /// Decoding runs off the main thread: a long file takes real time and the
    /// window must stay responsive while it happens.
    static func load(url: URL, pace: Pace) async throws -> FileFeed {
        FileFeed(
            audio: try await AudioDecoder.decode(url),
            label: url.lastPathComponent,
            pace: pace
        )
    }

    func chunks() -> AsyncThrowingStream<AudioChunk, Error> {
        let samples = audio.samples
        let frames = AudioFormats.chunkFrames
        let multiplier = pace.multiplier

        // Bounded on purpose. A microphone paces itself, so an unbounded queue
        // behind one never fills; "Fast" has nothing holding it back and would
        // push an hour of audio into the queue as quickly as it can slice it,
        // however slowly the recogniser is draining. `bufferingOldest` keeps
        // what is already queued and hands the newest chunk back instead of
        // silently dropping one, which is what makes the retry below safe.
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(Self.lookahead)) {
            continuation in
            let task = Task {
                var offset = 0
                // Pace against a fixed origin rather than sleeping a fixed amount
                // each turn, so decode time does not accumulate into drift.
                let origin = ContinuousClock.now

                while offset < samples.count, !Task.isCancelled {
                    let end = min(offset + frames, samples.count)
                    let position = Double(offset) / Double(AudioFormats.sampleRate)

                    if let buffer = AudioDecoder.makeBuffer(samples[offset..<end]) {
                        let chunk = AudioChunk(
                            buffer: buffer,
                            peak: AudioChunk.peakMagnitude(of: buffer),
                            position: position
                        )
                        // Offer it again rather than lose it. Nothing here is
                        // live, so waiting for the reader costs only time.
                        var queued = false
                        while !queued, !Task.isCancelled {
                            switch continuation.yield(chunk) {
                            case .enqueued:
                                queued = true
                            case .dropped:
                                try? await Task.sleep(for: .milliseconds(5))
                            case .terminated:
                                return
                            @unknown default:
                                queued = true
                            }
                        }
                    }
                    offset = end

                    if multiplier > 0 {
                        let target = Double(offset) / Double(AudioFormats.sampleRate) * multiplier
                        let deadline = origin.advanced(by: .seconds(target))
                        if deadline > .now {
                            try? await Task.sleep(until: deadline, clock: .continuous)
                        }
                    } else {
                        await Task.yield()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Six seconds of audio in hand, which is far more than any reader here is
    /// ever behind by and small enough to be beneath notice.
    private static let lookahead = 60
}
