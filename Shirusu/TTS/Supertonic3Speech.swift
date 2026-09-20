import AVFoundation
import ChatterboxTTS
import FluidAudio
import Foundation
import Observation

/// A small, UI-facing wrapper around FluidAudio's local TTS pipelines.
///
/// The heavy Core ML assets are intentionally fetched only when someone asks
/// Shirusu to speak. Transcription therefore stays fast to open, while a first
/// TTS run has an honest download state instead of looking stalled.
@MainActor
@Observable
final class SpeechSession {
    enum Phase: Equatable {
        case idle
        case preparing
        case synthesizing
        case playing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .preparing, .synthesizing: true
            case .idle, .playing, .failed: false
            }
        }
    }

    enum Language: String, CaseIterable, Identifiable {
        case portuguese = "pt"
        case english = "en"
        case spanish = "es"
        case french = "fr"
        case german = "de"
        case italian = "it"
        case japanese = "ja"
        case korean = "ko"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .portuguese: String(localized: "Portuguese")
            case .english: String(localized: "English")
            case .spanish: String(localized: "Spanish")
            case .french: String(localized: "French")
            case .german: String(localized: "German")
            case .italian: String(localized: "Italian")
            case .japanese: String(localized: "Japanese")
            case .korean: String(localized: "Korean")
            }
        }
    }

    enum Voice: String, CaseIterable, Identifiable {
        case f1 = "F1"
        case f2 = "F2"
        case f3 = "F3"
        case f4 = "F4"
        case f5 = "F5"
        case m1 = "M1"
        case m2 = "M2"
        case m3 = "M3"
        case m4 = "M4"
        case m5 = "M5"

        var id: String { rawValue }
    }

    var phase: Phase = .idle
    var downloadFraction = 0.0

    @ObservationIgnored private let engine = SpeechEngine()
    @ObservationIgnored private var run = 0
    @ObservationIgnored private var synthesisTask: Task<Void, Never>?
    @ObservationIgnored private lazy var player = SpeechPlayer { [weak self] in
        self?.finishedPlaying()
    }

    var isPlaying: Bool { phase == .playing }

    func speak(
        text: String,
        backend: SpeechBackend,
        language: Language,
        voice: Voice,
        chatterbox: ChatterboxControls,
        mlxAudio: MLXAudioControls,
        referenceAudio: URL?,
        lyricLines: [VoiceLine]
    ) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            phase = .failed(String(localized: "Write something for Shirusu to say."))
            return
        }
        guard backend != .mlxAudio || referenceAudio != nil else {
            phase = .failed(String(localized: "Choose a voice recording before using Voice Cloning Advanced."))
            return
        }

        stop()
        run &+= 1
        let thisRun = run
        downloadFraction = 0
        phase = .preparing

        synthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let localReference = try referenceAudio.map(Self.copyReferenceAudio)
                defer {
                    if let localReference {
                        try? FileManager.default.removeItem(at: localReference)
                    }
                }

                let audio = try await engine.synthesize(
                    backend: backend,
                    text: text,
                    language: language.rawValue,
                    voice: Supertonic3Voice(rawValue: voice.rawValue) ?? .default,
                    chatterbox: chatterbox,
                    mlxAudio: mlxAudio,
                    referenceAudio: localReference,
                    lyricLines: lyricLines,
                    progress: { [weak self] update in
                        Task { @MainActor [weak self] in
                            guard let self, self.run == thisRun else { return }
                            self.downloadFraction = update.fractionCompleted
                        }
                    },
                    willSynthesize: { [weak self] in
                        Task { @MainActor [weak self] in
                            guard let self, self.run == thisRun else { return }
                            self.phase = .synthesizing
                        }
                    }
                )

                guard !Task.isCancelled, run == thisRun else { return }
                try player.play(audio)
                phase = .playing
            } catch is CancellationError {
                // A later request owns the player now.
            } catch {
                guard run == thisRun else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        run &+= 1
        synthesisTask?.cancel()
        synthesisTask = nil
        player.stop()
        if case .failed = phase {
            return
        }
        phase = .idle
    }

    func clearFailure() {
        if case .failed = phase { phase = .idle }
    }

    private func finishedPlaying() {
        guard phase == .playing else { return }
        phase = .idle
    }

    /// Copy the user-selected reference into a private temporary URL before
    /// asynchronous decoding. That keeps its security scope inside the app and
    /// makes the copy disappear as soon as synthesis ends.
    private static func copyReferenceAudio(_ source: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped { source.stopAccessingSecurityScopedResource() }
        }

        let suffix = source.pathExtension.isEmpty ? "audio" : source.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("shirusu-voice-reference-\(UUID().uuidString)")
            .appendingPathExtension(suffix)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}

/// The local models exposed by the app. They intentionally remain distinct
/// rather than treating voices as interchangeable: Supertonic has ten preset
/// speakers, while FluidAudio's Chatterbox conversion currently has one.
enum SpeechBackend: String, CaseIterable, Identifiable, Sendable {
    case supertonic3
    case chatterbox
    case mlxAudio

    var id: String { rawValue }

    var label: String {
        switch self {
        case .supertonic3: String(localized: "Supertonic 3")
        case .chatterbox: String(localized: "Chatterbox (built-in voice)")
        case .mlxAudio: String(localized: "Voice Cloning Advanced")
        }
    }

    func supports(_ language: SpeechSession.Language) -> Bool {
        switch self {
        case .supertonic3:
            true
        case .chatterbox:
            // FluidAudio's Chatterbox text frontend does not currently carry
            // its Japanese/Korean transforms.
            language != .japanese && language != .korean
        case .mlxAudio:
            true
        }
    }
}

/// Controls currently exposed by FluidAudio's Chatterbox Manager. They affect
/// sampling and therefore delivery/prosody; they are not a substitute for a
/// reference-voice or emotion embedding, neither of which the SDK exposes yet.
struct ChatterboxControls: Sendable {
    var guidance: Float = 0.5
    var temperature: Float = 0.8
    var seed: UInt64 = UInt64.random(in: 0..<UInt64.max)
}

/// These map one-to-one to speech-swift's native Chatterbox MLX clone API.
/// Unlike FluidAudio's Chatterbox sampler values, `exaggeration` conditions
/// the model's actual emotion vector.
nonisolated struct MLXAudioControls: Sendable {
    var exaggeration: Float = 0.5
    var cfgWeight: Float = 0.5
    var temperature: Float = 0.8
    var repetitionPenalty: Float = 1.2
    var minP: Float = 0.05
    var topP: Float = 1.0

    func adjusted(for line: VoiceLine) -> MLXAudioControls {
        var adjusted = self
        adjusted.exaggeration = line.tone.exaggeration
        adjusted.cfgWeight = line.pace.cfgWeight
        return adjusted
    }
}

/// Uma linha independente permite dirigir a leitura de uma letra sem expor
/// parâmetros de amostragem para quem só quer escolher como ela deve soar.
nonisolated struct VoiceLine: Identifiable, Sendable, Equatable {
    nonisolated enum Tone: String, CaseIterable, Identifiable, Sendable {
        case calm
        case natural
        case lively
        case dramatic

        var id: String { rawValue }

        var label: String {
            switch self {
            case .calm: String(localized: "Calm")
            case .natural: String(localized: "Natural")
            case .lively: String(localized: "Lively")
            case .dramatic: String(localized: "Dramatic")
            }
        }

        var exaggeration: Float {
            switch self {
            case .calm: 0.2
            case .natural: 0.5
            case .lively: 0.72
            case .dramatic: 0.9
            }
        }
    }

    nonisolated enum Pace: String, CaseIterable, Identifiable, Sendable {
        case slow
        case normal
        case quick

        var id: String { rawValue }

        var label: String {
            switch self {
            case .slow: String(localized: "Slow")
            case .normal: String(localized: "Normal")
            case .quick: String(localized: "Quick")
            }
        }

        var cfgWeight: Float {
            switch self {
            case .slow: 0.3
            case .normal: 0.5
            case .quick: 0.7
            }
        }
    }

    let id: UUID
    var text: String
    var tone: Tone
    var pace: Pace

    init(text: String, tone: Tone = .natural, pace: Pace = .normal) {
        id = UUID()
        self.text = text
        self.tone = tone
        self.pace = pace
    }

    static func makeLines(from text: String) -> [VoiceLine] {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { VoiceLine(text: $0) }
    }
}

private struct SpeechAudio: Sendable {
    let samples: [Float]
    let sampleRate: Int

    nonisolated static func samples(_ samples: [Float], sampleRate: Int) -> SpeechAudio {
        SpeechAudio(samples: samples, sampleRate: sampleRate)
    }
}

/// Holds FluidAudio's actor for the lifetime of the app. The ANE-bucketed
/// int4 estimator is a particularly good fit for an interactive Mac app: it
/// downloads the compact variant and leaves the Neural Engine free of the
/// dynamic-shape CPU/GPU fallback used by the upstream default.
private actor SpeechEngine {
    private let supertonic = Supertonic3Manager(vectorEstimator: .aneBucketed(.int4))
    private let chatterbox = ChatterboxManager()
    private var hasSupertonicPrepared = false
    private var hasChatterboxPrepared = false
    private var supertonicStyles: [Supertonic3Voice: Supertonic3VoiceStyle] = [:]
    private var chatterboxMLX: ChatterboxTTSModel?

    func synthesize(
        backend: SpeechBackend,
        text: String,
        language: String,
        voice: Supertonic3Voice,
        chatterbox controls: ChatterboxControls,
        mlxAudio: MLXAudioControls,
        referenceAudio: URL?,
        lyricLines: [VoiceLine],
        progress: @escaping ProgressHandler,
        willSynthesize: @escaping @Sendable () -> Void
    ) async throws -> SpeechAudio {
        switch backend {
        case .supertonic3:
            return try await synthesizeSupertonic(
                text: text, language: language, voice: voice,
                progress: progress, willSynthesize: willSynthesize)
        case .chatterbox:
            return try await synthesizeChatterbox(
                text: text, language: language, controls: controls,
                progress: progress, willSynthesize: willSynthesize)
        case .mlxAudio:
            guard let referenceAudio else {
                throw SpeechEngineError.missingChatterboxReference
            }
            return try await synthesizeChatterboxMLX(
                text: text, language: language, controls: mlxAudio,
                referenceAudio: referenceAudio, lyricLines: lyricLines, progress: progress,
                willSynthesize: willSynthesize)
        }
    }

    private func synthesizeSupertonic(
        text: String,
        language: String,
        voice: Supertonic3Voice,
        progress: @escaping ProgressHandler,
        willSynthesize: @escaping @Sendable () -> Void
    ) async throws -> SpeechAudio {
        if !hasSupertonicPrepared {
            try await Supertonic3ResourceDownloader.ensureModels(
                veVariant: "ane-int4", progressHandler: progress)
            try await supertonic.initialize()
            hasSupertonicPrepared = true
        }

        let style: Supertonic3VoiceStyle
        if let cached = supertonicStyles[voice] {
            style = cached
        } else {
            style = try await Supertonic3ResourceDownloader.loadVoiceStyle(
                voice, progressHandler: progress)
            supertonicStyles[voice] = style
        }

        willSynthesize()
        let result = try await supertonic.synthesize(text: text, language: language, style: style)
        return .samples(result.samples, sampleRate: Supertonic3Constants.sampleRate)
    }

    private func synthesizeChatterbox(
        text: String,
        language: String,
        controls: ChatterboxControls,
        progress: @escaping ProgressHandler,
        willSynthesize: @escaping @Sendable () -> Void
    ) async throws -> SpeechAudio {
        if !hasChatterboxPrepared {
            try await chatterbox.initialize(progressHandler: progress)
            hasChatterboxPrepared = true
        }

        willSynthesize()
        let result = try await chatterbox.synthesize(
            text: text,
            language: language,
            cfgWeight: controls.guidance,
            temperature: controls.temperature,
            seed: controls.seed)
        return .samples(result.samples, sampleRate: result.sampleRate)
    }

    private func synthesizeChatterboxMLX(
        text: String,
        language: String,
        controls: MLXAudioControls,
        referenceAudio: URL,
        lyricLines: [VoiceLine],
        progress: @escaping ProgressHandler,
        willSynthesize: @escaping @Sendable () -> Void
    ) async throws -> SpeechAudio {
        let model: ChatterboxTTSModel
        if let chatterboxMLX {
            model = chatterboxMLX
        } else {
            model = try await ChatterboxTTSModel.fromPretrained { fraction, _ in
                progress(DownloadProgress(
                    fractionCompleted: fraction,
                    phase: .downloading(completedFiles: 0, totalFiles: 0)
                ))
            }
            chatterboxMLX = model
        }

        // `AudioDecoder` gives the model a mono Float32 reference at 16 kHz.
        // It supports every user-selectable file type and keeps its security
        // scope handling inside the app rather than leaking it into the model.
        let reference = try await AudioDecoder.decode(referenceAudio)
        willSynthesize()
        let lines = lyricLines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let requests: [(text: String, controls: MLXAudioControls)]
        if lines.isEmpty {
            requests = [(text, controls)]
        } else {
            requests = lines.map { ($0.text, controls.adjusted(for: $0)) }
        }

        var samples: [Float] = []
        for (index, request) in requests.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let line = try model.clone(
                referenceSamples: reference.samples,
                sampleRate: AudioFormats.sampleRate,
                text: request.text,
                languageId: language,
                exaggeration: request.controls.exaggeration,
                temperature: request.controls.temperature,
                topP: request.controls.topP,
                minP: request.controls.minP,
                repetitionPenalty: request.controls.repetitionPenalty,
                cfgWeight: request.controls.cfgWeight,
                memoryOptions: .balanced)
            samples += line
            if index < requests.endIndex - 1 {
                samples += Array(repeating: 0, count: 4_800)
            }
        }
        return .samples(samples, sampleRate: 24_000)
    }
}

private enum SpeechEngineError: LocalizedError {
    case missingChatterboxReference

    var errorDescription: String? {
        switch self {
        case .missingChatterboxReference:
            return String(localized: "Voice Cloning Advanced needs a recording to copy the voice.")
        }
    }
}

/// Both engines are batch TTS and return a complete mono Float32 waveform.
/// Keeping playback separate from inference lets a new request stop the last
/// utterance immediately.
@MainActor
private final class SpeechPlayer: NSObject, AVAudioPlayerDelegate {
    private let didFinish: () -> Void
    private var audioPlayer: AVAudioPlayer?

    init(didFinish: @escaping () -> Void) {
        self.didFinish = didFinish
    }

    func play(_ audio: SpeechAudio) throws {
        let data = WavEncoder.data(samples: audio.samples, sampleRate: audio.sampleRate)
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.prepareToPlay()
        audioPlayer = player
        guard player.play() else {
            audioPlayer = nil
            throw SpeechPlaybackError.couldNotStart
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audioPlayer else { return }
        audioPlayer = nil
        didFinish()
    }
}

private enum SpeechPlaybackError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        String(localized: "Shirusu could not play the generated voice.")
    }
}

/// FluidAudio returns Float32 PCM, while AVAudioPlayer gives the most reliable
/// macOS playback path for a small RIFF/WAV container. Conversion is kept at
/// the boundary only; model synthesis remains entirely FluidAudio.
private enum WavEncoder {
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
