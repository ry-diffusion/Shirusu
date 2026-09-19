import AVFoundation

/// A slice of audio on its way to the recogniser.
///
/// `AVAudioPCMBuffer` is a reference type and not `Sendable`, but every buffer
/// here is filled once by its producer and then only read, so handing it across
/// isolation boundaries is safe.
nonisolated struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    /// Peak magnitude in this chunk, 0...1. Drives the level meter only.
    let peak: Float
    /// Playhead inside the source when this chunk starts.
    let position: TimeInterval

    static func peakMagnitude(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(samples[frame]))
            }
        }
        return min(peak, 1)
    }
}

/// Anything that can produce audio for the pipeline. The microphone and a decoded
/// file both land here, so everything downstream is written once.
nonisolated protocol AudioFeed: Sendable {
    /// Total length, when the source has one. `nil` means open-ended (a live mic).
    var duration: TimeInterval? { get }
    /// A human-readable name for the source, shown in the UI.
    var label: String { get }
    func chunks() -> AsyncThrowingStream<AudioChunk, Error>
}

/// Frames seen so far. The tap block is sendable and may be called from any
/// isolation domain, so the running total needs a lock rather than a captured var.
nonisolated final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0

    /// Returns the position *before* this chunk, then adds it.
    func advance(by count: Int) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let start = frames
        frames += count
        return Double(start)
    }
}

