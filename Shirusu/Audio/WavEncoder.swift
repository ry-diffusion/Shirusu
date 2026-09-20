import Foundation

/// Float32 PCM into a small RIFF/WAV container.
///
/// Both ends of the app need this: AVAudioPlayer wants a container rather
/// than samples to play a synthesised voice, and a recorded reference has to
/// reach disk as a file the decoder can read back. Conversion stays at those
/// boundaries; nothing in between leaves Float32.
nonisolated enum WavEncoder {
    static func data(samples: [Float], sampleRate: Int) -> Data {
        let bytesPerSample = UInt32(MemoryLayout<Int16>.size)
        let sampleBytes = UInt32(samples.count) * bytesPerSample
        var data = Data()
        data.reserveCapacity(Int(44 + sampleBytes))

        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36) + sampleBytes, to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &data) // PCM format chunk size
        append(UInt16(1), to: &data) // PCM
        append(UInt16(1), to: &data) // mono
        let sampleRate = UInt32(sampleRate)
        append(sampleRate, to: &data)
        append(sampleRate * bytesPerSample, to: &data)
        append(UInt16(bytesPerSample), to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        append(sampleBytes, to: &data)

        for sample in samples {
            let clipped = min(1, max(-1, sample))
            append(Int16((clipped * Float(Int16.max)).rounded()), to: &data)
        }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
