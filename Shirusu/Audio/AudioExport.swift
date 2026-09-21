import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// What a finished take can be saved as.
///
/// No MP3, and not for want of trying: Core Audio ships an MP3 decoder and no
/// encoder, so asking for one fails at `ExtAudioFileSetProperty` rather than
/// producing a file. Writing MP3 would mean bundling LAME — a dependency, a
/// licence to honour and a build to change — to land somewhere AAC already is.
nonisolated enum AudioExport: String, CaseIterable, Identifiable, Sendable {
    /// What the model produced, sample for sample.
    case wav
    /// AAC in an MPEG-4 container: a tenth of the size, and the compressed
    /// format macOS can actually write.
    case m4a

    var id: String { rawValue }

    var contentType: UTType {
        switch self {
        case .wav: .wav
        case .m4a: .m4a
        }
    }

    var label: String {
        switch self {
        case .wav: String(localized: "WAV — every sample kept")
        case .m4a: String(localized: "M4A — smaller file")
        }
    }

    func encode(samples: [Float], sampleRate: Int) throws -> Data {
        switch self {
        case .wav: WavEncoder.data(samples: samples, sampleRate: sampleRate)
        case .m4a: try Self.aac(samples: samples, sampleRate: sampleRate)
        }
    }

    private static func aac(samples: [Float], sampleRate: Int) throws -> Data {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: 1,
                interleaved: false),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { throw AudioExportError.couldNotEncode }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }

        let url = FileManager.default.temporaryDirectory
            .appending(path: "shirusu-export-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        // Scoped so the file is closed before it is read back: an AVAudioFile
        // flushes what it is holding when it goes away, and reading first gives
        // a truncated take.
        do {
            // No bitrate asked for. AAC's valid range depends on the rate and
            // the channel count, and naming one that a 16 kHz mono stream
            // cannot take fails the whole encode at
            // `AudioConverterSetProperty` — which is what a Supertonic take
            // would have done. Left alone, the encoder picks a rate that works
            // at every rate the app produces.
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                ])
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }
}

extension UTType {
    /// `com.apple.m4a-audio`, which the system declares and
    /// UniformTypeIdentifiers has no constant for.
    ///
    /// Not `.mpeg4Audio`: that one is `public.mpeg-4-audio`, and its preferred
    /// extension is `mp4`. The container is the same either way — what changes
    /// is the name the file lands under, and a menu item reading M4A that
    /// hands back an `.mp4` is a promise broken in the Finder.
    nonisolated static let m4a = UTType("com.apple.m4a-audio") ?? .mpeg4Audio
}

enum AudioExportError: LocalizedError {
    case couldNotEncode

    var errorDescription: String? {
        String(localized: "Shirusu could not package that audio for saving.")
    }
}

/// A finished take, on its way to a file the person chooses.
///
/// Write-only on purpose: nothing in the app opens one of these back, and a
/// document type that claims it can read is one that gets offered as an
/// importer somewhere it makes no sense.
nonisolated struct SpeechDocument: FileDocument {
    static let readableContentTypes: [UTType] = []
    // Taken from the cases rather than listed again. A type offered in the
    // menu but missing here is not refused: the exporter quietly writes the
    // first entry instead, so the two lists disagreeing costs a file in the
    // wrong format rather than an error.
    static let writableContentTypes: [UTType] = AudioExport.allCases.map(\.contentType)

    let samples: [Float]
    let sampleRate: Int
    let format: AudioExport

    init(samples: [Float], sampleRate: Int, format: AudioExport) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.format = format
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try format.encode(samples: samples, sampleRate: sampleRate))
    }
}
