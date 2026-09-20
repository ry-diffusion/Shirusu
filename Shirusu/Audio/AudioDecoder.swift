import AVFoundation
import FluidAudio
import Foundation

nonisolated struct DecodedAudio: Sendable {
    /// Mono Float32 at `sampleRate`.
    let samples: [Float]
    let sampleRate: Int

    var duration: TimeInterval { Double(samples.count) / Double(sampleRate) }
}

nonisolated enum AudioFormats {
    /// The only rate the recogniser accepts.
    static let sampleRate = 16_000

    /// What the voice-cloning model builds its prompt mel at.
    ///
    /// Decoding a reference at 16 kHz and letting the model upsample left a
    /// 24 kHz mel with nothing above 8 kHz in it — a ceiling on every copied
    /// voice, including one recorded from a microphone that had the detail to
    /// give. Decoding straight to 24 kHz keeps it.
    static let referenceSampleRate = 24_000
    /// 100 ms. Small enough for a responsive level meter, large enough that we
    /// are not waking the recogniser constantly.
    static let chunkFrames = 1_600

    static let pcm16kMono = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(sampleRate),
        channels: 1,
        interleaved: false
    )!

}

enum AudioDecoderError: LocalizedError {
    case unreadable(URL, underlying: Error, isOgg: Bool)
    case empty(URL)

    var errorDescription: String? {
        switch self {
        case .empty(let url):
            return String(
                localized: "“\(url.lastPathComponent)” decoded to silence.",
                comment: "Error when a file contains no audio")
        case .unreadable(let url, let underlying, let isOgg):
            let reason = String(
                localized: "Could not read “\(url.lastPathComponent)”: \(underlying.localizedDescription)",
                comment: "Generic audio decoding failure")
            guard isOgg else { return reason }
            // CoreAudio lists Ogg among its readable containers, so reaching here
            // means this particular file is damaged or uses a codec inside Ogg
            // that the system does not carry. Re-wrapping is the usual fix.
            return reason + " " + String(
                localized: "Re-wrapping it as .caf or .m4a usually works.",
                comment: "Hint appended when an Ogg file fails to decode")
        }
    }
}

/// Turns any file the system can open into mono Float32 at the rate asked for.
nonisolated enum AudioDecoder {
    static func decode(
        _ url: URL,
        sampleRate: Int = AudioFormats.sampleRate
    ) async throws -> DecodedAudio {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        var firstFailure: Error?

        // FluidAudio's converter is the documented path: it drives AVAudioConverter
        // for rate, depth and channel changes in one pass. It only ever produces
        // 16 kHz, so it is the fast path for the recogniser and no use to a
        // reference that wants more.
        if sampleRate == AudioFormats.sampleRate {
            do {
                let samples = try AudioConverter().resampleAudioFile(url)
                if !samples.isEmpty {
                    return DecodedAudio(samples: samples, sampleRate: sampleRate)
                }
            } catch {
                firstFailure = error
            }
        }

        // AVAudioFile refuses a few containers that AVAssetReader still handles,
        // video files among them.
        do {
            let samples = try await decodeViaAsset(url, sampleRate: sampleRate)
            if !samples.isEmpty {
                return DecodedAudio(samples: samples, sampleRate: sampleRate)
            }
        } catch {
            firstFailure = firstFailure ?? error
        }

        if let firstFailure {
            throw AudioDecoderError.unreadable(url, underlying: firstFailure, isOgg: isOgg(url))
        }
        throw AudioDecoderError.empty(url)
    }

    /// Ogg pages start with the capture pattern "OggS". macOS 27 reads this
    /// container, so this is only used to word a failure helpfully; the extension
    /// alone lies often enough to be worth checking the bytes.
    private static func isOgg(_ url: URL) -> Bool {
        if ["ogg", "oga", "opus"].contains(url.pathExtension.lowercased()) { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("OggS".utf8)
    }

    private static func decodeViaAsset(_ url: URL, sampleRate: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return []
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        )
        guard reader.canAdd(output) else { return [] }
        let provider = reader.outputProvider(for: output)
        try reader.start()

        var samples: [Float] = []
        while let ready = try await provider.next() {
            guard case .dataBuffer(let block) = ready.content else { continue }
            let bytes = Data(block)
            samples.append(contentsOf: bytes.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self))
            })
        }

        if reader.status == .failed, let error = reader.error { throw error }
        return samples
    }

    /// Wraps a run of 16 kHz mono samples into a buffer the recogniser accepts.
    static func makeBuffer(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer? {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: AudioFormats.pcm16kMono,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let destination = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                destination.update(from: source.baseAddress!, count: source.count)
            }
        }
        return buffer
    }
}
