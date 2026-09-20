import AVFoundation
import Foundation

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

extension AudioFeed {
    /// Opens the source away from whoever asked for it.
    ///
    /// Building the stream is not the bookkeeping it looks like. The
    /// microphone negotiates a format with the hardware and waits for the HAL
    /// to hand back an IO thread; the system tap builds an aggregate device.
    /// Both happen synchronously inside `chunks()`, and `chunks()` runs
    /// wherever it is called — which, for every caller here, was the main
    /// actor, with the window held still for as long as CoreAudio took.
    func opened() async -> AsyncThrowingStream<AudioChunk, Error> {
        await withCheckedContinuation { resume in
            // A real thread rather than the cooperative pool: opening a device
            // blocks, and blocking a pool thread starves everything else that
            // was waiting to run on it.
            DispatchQueue.global(qos: .userInitiated).async {
                resume.resume(returning: self.chunks())
            }
        }
    }
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

