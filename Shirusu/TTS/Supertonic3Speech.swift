import AVFoundation
import AudioCommon
import ChatterboxTTS
import FluidAudio
import Foundation
import OSLog
import MLX
import Observation
import VoxCPM2TTS

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

    /// Load a backend's weights before anyone presses play, so the first press
    /// is not spent reading a multi-gigabyte bundle off disk. Nothing is
    /// fetched here: a backend whose weights have not been downloaded yet is
    /// left alone, and keeps its honest download state on the first request.
    func prepare(for backend: SpeechBackend) {
        Task { [engine] in await engine.preload(backend) }
    }

    func speak(
        text: String,
        backend: SpeechBackend,
        language: Language,
        voice: Voice,
        mlxAudio: MLXAudioControls,
        referenceAudio: URL?,
        cloning: CloningEngine,
        voiceDescription: String,
        lyricLines: [VoiceLine]
    ) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            phase = .failed(String(localized: "Write something for Shirusu to say."))
            return
        }
        guard backend != .mlxAudio || referenceAudio != nil else {
            phase = .failed(String(localized: "Choose a recording before copying a voice."))
            return
        }
        let voiceDescription = voiceDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard backend != .voiceDesign || !voiceDescription.isEmpty else {
            phase = .failed(String(localized: "Describe the voice you want before asking for it."))
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
                    mlxAudio: mlxAudio,
                    referenceAudio: localReference,
                    cloning: cloning,
                    voiceDescription: voiceDescription,
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

/// The three things someone can ask for, named by the result rather than by
/// the model behind it: a voice that is ready to speak, their own voice copied
/// from a recording, or a voice built from a description of it. All three cover
/// every language the app offers, so choosing one never changes what else is on
/// the screen.
enum SpeechBackend: String, CaseIterable, Identifiable, Sendable {
    case supertonic3
    case mlxAudio
    case voiceDesign

    var id: String { rawValue }

    var label: String {
        switch self {
        case .supertonic3: String(localized: "A ready voice")
        case .mlxAudio: String(localized: "Copy a voice from a recording")
        case .voiceDesign: String(localized: "Describe a voice")
        }
    }

    /// Whether this one holds a multi-gigabyte model of its own. Two of them
    /// resident at once is more than a Mac should be asked to carry for a
    /// feature nobody is using at that moment.
    var isHeavy: Bool { self != .supertonic3 }
}

/// How a copied voice is made.
///
/// Two models can copy a voice, and they differ in ways someone can hear and
/// feel rather than in their names — so this asks which of those they want,
/// not which model to run.
nonisolated enum CloningEngine: String, CaseIterable, Identifiable, Sendable {
    /// Chatterbox: 24 kHz out, about 1.7 GB, and the quicker of the two.
    case quick
    /// VoxCPM2: 48 kHz out, about 3.2 GB, and the only one that will take a
    /// note on how to deliver the line as well as whose voice to use.
    case detailed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quick: String(localized: "Quicker")
        case .detailed: String(localized: "Higher quality")
        }
    }

    /// Whether it will read a note on delivery beside the recording.
    var takesDirection: Bool { self == .detailed }
}

/// These map one-to-one to speech-swift's native Chatterbox MLX clone API.
/// `exaggeration` conditions the model's actual emotion vector, which is why it
/// is worth a control while the pure sampling knobs below are not.
nonisolated struct MLXAudioControls: Sendable {
    var exaggeration: Float = 0.5
    var cfgWeight: Float = 0.5
    var temperature: Float = 0.8

    /// Sampling vocabulary. Nobody can hear what a min-p of 0.05 does, so
    /// these stay out of the way behind Technical options; the defaults are
    /// the ones `clone` uses, and most people never move them.
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
    private static let log = Logger(subsystem: "br.com.zesmoi.Shirusu", category: "speech")

    private let supertonic = Supertonic3Manager(vectorEstimator: .aneBucketed(.int4))
    private var hasSupertonicPrepared = false
    private var supertonicStyles: [Supertonic3Voice: Supertonic3VoiceStyle] = [:]
    private var chatterboxMLX: ChatterboxTTSModel?
    private var chatterboxMLXLoad: Task<ChatterboxTTSModel, Error>?
    private var voxcpm: VoxCPM2TTSModel?
    private var voxcpmLoad: Task<VoxCPM2TTSModel, Error>?

    /// The repos to try, in order. The first is what was asked for; the second
    /// is what `speech-swift` is written and tested against, so it is the one
    /// that decides whether the feature works at all.
    ///
    /// A first entry that downloads and then fails to load costs its download,
    /// which is why the tested repo is not first.
    private static let voxcpmModelIds = [
        "mlx-community/VoxCPM2-8bit",
        VoxCPM2TTSModel.int8ModelId,
    ]
    private var clonedVoices: [ClonedVoice] = []

    /// A cached voice is a few hundred KB, so keeping the last handful costs
    /// little and makes switching back to an earlier take instant.
    private static let clonedVoiceLimit = 3
    private static let memoryOptions = ChatterboxMemoryOptions.balanced

    /// Warm a backend without synthesizing anything. Only weights already in
    /// the cache are loaded, so merely opening the tab never starts a download.
    func preload(_ backend: SpeechBackend) async {
        switch backend {
        case .supertonic3:
            // FluidAudio drives its own download inside `initialize`, with no
            // way to ask whether the assets are already there, so warming this
            // one could not tell a disk read from a fetch.
            break
        case .mlxAudio:
            guard chatterboxMLX == nil, Self.hasDownloadedChatterboxMLX else { return }
            _ = try? await loadChatterboxMLX(progress: { _ in })
        case .voiceDesign:
            // No cheap way to ask whether these weights are already here: the
            // repo that answers depends on which one loaded last time. Warming
            // it would risk starting a 3 GB download from opening a tab.
            break
        }
    }

    /// The two multi-gigabyte models. Which one a run needs no longer follows
    /// from the mode alone, since copying a voice can be either of them.
    private enum HeavyModel { case chatterbox, voxcpm }

    /// One heavy model at a time.
    ///
    /// Chatterbox holds around 1.7 GB and VoxCPM2 around 3.2, both promoted to
    /// float32 on Apple Silicon, and someone switching between modes is not
    /// asking to carry both at once. Chatterbox has no `unload`, so letting go
    /// of the reference and clearing the cache is all there is; VoxCPM2 has one
    /// and it is worth calling.
    private func releaseModels(except wanted: HeavyModel) {
        var freed = false
        if wanted != .chatterbox, chatterboxMLX != nil {
            chatterboxMLX = nil
            // These hold MLXArrays built by the model that is going away.
            clonedVoices.removeAll()
            freed = true
        }
        if wanted != .voxcpm, let voxcpm {
            voxcpm.unload()
            self.voxcpm = nil
            freed = true
        }
        if freed { Memory.clearCache() }
    }

    func synthesize(
        backend: SpeechBackend,
        text: String,
        language: String,
        voice: Supertonic3Voice,
        mlxAudio: MLXAudioControls,
        referenceAudio: URL?,
        cloning: CloningEngine,
        voiceDescription: String,
        lyricLines: [VoiceLine],
        progress: @escaping ProgressHandler,
        willSynthesize: @escaping @Sendable () -> Void
    ) async throws -> SpeechAudio {
        switch backend {
        case .supertonic3:
            return try await synthesizeSupertonic(
                text: text, language: language, voice: voice,
                progress: progress, willSynthesize: willSynthesize)
        case .voiceDesign:
            return try await synthesizeVoiceDesign(
                text: text, language: language, description: voiceDescription,
                progress: progress, willSynthesize: willSynthesize)
        case .mlxAudio where cloning == .detailed:
            guard let referenceAudio else {
                throw SpeechEngineError.missingChatterboxReference
            }
            return try await synthesizeVoxCloning(
                text: text, language: language, referenceAudio: referenceAudio,
                direction: voiceDescription, progress: progress,
                willSynthesize: willSynthesize)
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

    private func synthesizeChatterboxMLX(
        text: String,
        language: String,
        controls: MLXAudioControls,
        referenceAudio: URL,
        lyricLines: [VoiceLine],
        progress: @escaping ProgressHandler,
        willSynthesize: @escaping @Sendable () -> Void
    ) async throws -> SpeechAudio {
        // `clone` folded case before checking, and the tokenizer's table is
        // lowercase; matching it keeps the guard honest for any caller.
        let language = language.lowercased()
        guard MTLTokenizer.supportedLanguages.contains(language) else {
            throw SpeechEngineError.unsupportedCloneLanguage(language)
        }
        let model = try await loadChatterboxMLX(progress: progress)

        // Decoded at the rate the model builds its prompt mel at, not at the
        // recogniser's. At 16 kHz the mel was an upsample with nothing above
        // 8 kHz in it, which put a ceiling on every copied voice.
        let reference = try await AudioDecoder.decode(
            referenceAudio, sampleRate: AudioFormats.referenceSampleRate)
        willSynthesize()
        let lines = lyricLines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let requests: [(text: String, controls: MLXAudioControls)]
        if lines.isEmpty {
            requests = [(text, controls)]
        } else {
            requests = lines.map { ($0.text, controls.adjusted(for: $0)) }
        }

        let samples = try withGenerationMemoryCap { () throws -> [Float] in
            // Conditioning depends on the recording, never on the text, so a
            // lyric pays for it once rather than once per line.
            let voice = conditioning(
                for: reference.samples, sampleRate: reference.sampleRate, model: model)
            var samples: [Float] = []
            for (index, request) in requests.enumerated() {
                if Task.isCancelled { throw CancellationError() }
                samples += try speak(
                    request.text, as: voice, language: language,
                    controls: request.controls, model: model)
                if index < requests.endIndex - 1 {
                    samples += Array(repeating: 0, count: 4_800)
                }
            }
            return samples
        }
        return .samples(samples, sampleRate: 24_000)
    }

    /// A voice from a description of it, with no recording anywhere.
    ///
    /// VoxCPM2 takes the description as an instruction rather than as something
    /// to read, which is why this is its own mode and not a field on the other
    /// one: there is no reference here to condition on at all.
    private func synthesizeVoiceDesign(
        text: String,
        language: String,
        description: String,
        progress: @escaping ProgressHandler,
        willSynthesize: @escaping @Sendable () -> Void
    ) async throws -> SpeechAudio {
        let model = try await loadVoxCPM(progress: progress)
        willSynthesize()
        let samples = try await model.generateVoxCPM2(
            text: text, language: language, instruct: description)
        return .samples(samples, sampleRate: model.sampleRate)
    }

    /// A copied voice through VoxCPM2: 48 kHz out, and a note on delivery
    /// alongside the recording, which Chatterbox has nowhere to put.
    private func synthesizeVoxCloning(
        text: String,
        language: String,
        referenceAudio: URL,
        direction: String,
        progress: @escaping ProgressHandler,
        willSynthesize: @escaping @Sendable () -> Void
    ) async throws -> SpeechAudio {
        let model = try await loadVoxCPM(progress: progress)

        // The VAE asserts its own rate rather than resampling to it, and a
        // `precondition` traps in release as well — so the reference is decoded
        // at whatever rate this checkpoint was built for rather than at ours.
        let reference = try await AudioDecoder.decode(
            referenceAudio, sampleRate: model.audio_vae.sampleRate)

        willSynthesize()
        let samples = try await model.generateVoxCPM2(
            text: text,
            language: language,
            refAudio: reference.samples,
            instruct: direction.isEmpty ? nil : direction)
        return .samples(samples, sampleRate: model.sampleRate)
    }

    private func loadVoxCPM(progress: @escaping ProgressHandler) async throws -> VoxCPM2TTSModel {
        if let voxcpm { return voxcpm }
        if let voxcpmLoad { return try await voxcpmLoad.value }

        releaseModels(except: .voxcpm)
        let load = Task {
            var lastFailure: Error?
            for modelId in Self.voxcpmModelIds {
                do {
                    return try await VoxCPM2TTSModel.fromPretrained(modelId: modelId) { fraction, _ in
                        progress(DownloadProgress(
                            fractionCompleted: fraction,
                            phase: .downloading(completedFiles: 0, totalFiles: 0)
                        ))
                    }
                } catch {
                    Self.log.notice(
                        "VoxCPM2 could not load \(modelId, privacy: .public); trying the next repo")
                    lastFailure = error
                }
            }
            throw lastFailure ?? SpeechEngineError.missingVoiceDescription
        }
        voxcpmLoad = load
        defer { voxcpmLoad = nil }
        let model = try await load.value
        voxcpm = model
        return model
    }

    /// One shared load: `preload` and a play pressed straight afterwards would
    /// otherwise both find an empty slot and read the bundle twice. Whichever
    /// call starts the load owns the progress reporting — which only matters on
    /// a cold cache, since `preload` bows out unless the files are already there.
    private func loadChatterboxMLX(
        progress: @escaping ProgressHandler
    ) async throws -> ChatterboxTTSModel {
        if let chatterboxMLX { return chatterboxMLX }
        if let chatterboxMLXLoad { return try await chatterboxMLXLoad.value }

        releaseModels(except: .chatterbox)

        let load = Task {
            try await ChatterboxTTSModel.fromPretrained { fraction, _ in
                progress(DownloadProgress(
                    fractionCompleted: fraction,
                    phase: .downloading(completedFiles: 0, totalFiles: 0)
                ))
            }
        }
        chatterboxMLXLoad = load
        defer { chatterboxMLXLoad = nil }
        let model = try await load.value
        chatterboxMLX = model
        return model
    }

    /// Mirrors `prepare_conditionals` inside `ChatterboxTTSModel.clone`, which
    /// rebuilds all of this on every call. The S3Gen prompt wants 24 kHz capped
    /// at ten seconds, its tokenizer and CAMPPlus want that same slice at
    /// 16 kHz, and the voice encoder wants the untruncated take.
    private func conditioning(
        for samples: [Float],
        sampleRate: Int,
        model: ChatterboxTTSModel
    ) -> ClonedVoice {
        let digest = Self.digest(of: samples)
        if let index = clonedVoices.firstIndex(where: { $0.digest == digest }) {
            let cached = clonedVoices.remove(at: index)
            clonedVoices.insert(cached, at: 0)
            return cached
        }

        let at24k = sampleRate == ChatterboxS3Gen.sampleRate
            ? samples
            : AudioFileLoader.resample(
                samples, from: sampleRate, to: ChatterboxS3Gen.sampleRate, quality: .mastering)
        let reference24k = Array(at24k.prefix(ChatterboxTTSModel.decCondLen))
        let reference16k = AudioFileLoader.resample(
            reference24k, from: ChatterboxS3Gen.sampleRate, to: ChatterboxS3Gen.tokenSampleRate,
            quality: .mastering)

        // The voice encoder and the speech tokenizer want the whole take at
        // 16 kHz, whatever it arrived as.
        let at16k = sampleRate == ChatterboxS3Gen.tokenSampleRate
            ? samples
            : AudioFileLoader.resample(
                samples, from: sampleRate, to: ChatterboxS3Gen.tokenSampleRate,
                quality: .mastering)

        let s3Reference = model.s3gen.embedRef(refWav24k: reference24k, refWav16k: reference16k)
        let speakerEmbedding = model.voiceEncoder.embed(samples: at16k)
        let promptTokens = Array(
            model.s3gen.tokenizer
                .encode(Array(at16k.prefix(ChatterboxTTSModel.encCondLen)))
                .prefix(ChatterboxTTSModel.speechCondPromptLen))

        // Resolve the graphs before storing them: a cached array still carrying
        // its lazy graph would pin every intermediate it was built from.
        eval(s3Reference.xVector, s3Reference.promptFeat, speakerEmbedding)

        let voice = ClonedVoice(
            digest: digest,
            s3Reference: s3Reference,
            speakerEmbedding: speakerEmbedding,
            promptTokens: promptTokens)
        clonedVoices.insert(voice, at: 0)
        if clonedVoices.count > Self.clonedVoiceLimit { clonedVoices.removeLast() }
        return voice
    }

    /// The text-dependent half of `clone`, split out so the conditioning above
    /// can be reused across every line of a lyric.
    private func speak(
        _ text: String,
        as voice: ClonedVoice,
        language: String,
        controls: MLXAudioControls,
        model: ChatterboxTTSModel
    ) throws -> [Float] {
        let ids = try model.tokenizer.encodeStrict(text, languageId: language)
        let textTokens =
            [ChatterboxTTSModel.startTextToken] + ids + [ChatterboxTTSModel.stopTextToken]

        let generated = model.t3.inference(
            textTokens: textTokens,
            speakerEmb: voice.speakerEmbedding,
            promptSpeechTokens: voice.promptTokens,
            emotionAdv: controls.exaggeration,
            maxNewTokens: 1_000,
            temperature: controls.temperature,
            topP: controls.topP,
            minP: controls.minP,
            repetitionPenalty: controls.repetitionPenalty,
            cfgWeight: controls.cfgWeight)

        let speechTokens = Self.dropBoundaryTokens(generated)
            .filter { $0 < ChatterboxTTSModel.speechVocabSize }
        return model.s3gen.synthesize(
            speechTokens: speechTokens, ref: voice.s3Reference,
            memoryOptions: Self.memoryOptions)
    }

    /// `clone` ran a whole generation under a temporary MLX cache cap, and the
    /// package keeps `ChatterboxMemory` internal, so the cap is reapplied here.
    /// Without it the autoregressive T3 stage grows the buffer cache unchecked
    /// across a multi-line lyric.
    private func withGenerationMemoryCap<T>(_ body: () throws -> T) rethrows -> T {
        guard let cap = Self.memoryOptions.cacheLimitBytes else { return try body() }
        let previous = Memory.cacheLimit
        Memory.cacheLimit = min(previous, max(0, cap))
        Memory.clearCache()
        defer {
            Memory.cacheLimit = previous
            if Self.memoryOptions.clearCacheOnCompletion { Memory.clearCache() }
        }
        return try body()
    }

    /// `drop_invalid_tokens`: keep what falls between the first SOS and the
    /// first EOS. The package keeps its own copy internal.
    private static func dropBoundaryTokens(_ tokens: [Int]) -> [Int] {
        let sos = ChatterboxTTSModel.speechVocabSize
        let eos = sos + 1
        let start = tokens.firstIndex(of: sos).map { $0 + 1 } ?? 0
        let end = tokens.firstIndex(of: eos) ?? tokens.count
        guard start <= end else { return [] }
        return Array(tokens[start ..< end])
    }

    /// SipHash over the decoded samples, seeded per process — all this needs,
    /// since the cache never outlives the run.
    private static func digest(of samples: [Float]) -> Int {
        var hasher = Hasher()
        hasher.combine(samples.count)
        samples.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }

    /// The files `ChatterboxTTSModel.fromPretrained` insists on before it will
    /// load from the cache, repeated here so preloading stays a disk read. If
    /// any is missing the first real request downloads it, progress attached.
    private static var hasDownloadedChatterboxMLX: Bool {
        guard
            let bundle = try? HuggingFaceDownloader.getCacheDirectory(
                for: ChatterboxTTSModel.defaultModelId),
            let tokenizer = try? HuggingFaceDownloader.getCacheDirectory(
                for: ChatterboxTTSModel.s3TokenizerModelId,
                cacheDirName: "chatterbox-s3-tokenizer")
        else { return false }

        let fileManager = FileManager.default
        let required = ["model.safetensors", "config.json", "tokenizer.json", "Cangjie5_TC.json"]
        return required.allSatisfy {
            fileManager.fileExists(atPath: bundle.appendingPathComponent($0).path)
        } && fileManager.fileExists(
            atPath: tokenizer.appendingPathComponent("model.safetensors").path)
    }
}

/// Everything `ChatterboxTTSModel.clone` derives from the reference recording
/// before it ever looks at the text: three mastering-grade resamples, the
/// speaker encoder, the S3 tokenizer and the voice encoder.
nonisolated private struct ClonedVoice {
    let digest: Int
    let s3Reference: ChatterboxS3GenRef
    let speakerEmbedding: MLXArray
    let promptTokens: [Int]
}

private enum SpeechEngineError: LocalizedError {
    case missingChatterboxReference
    case missingVoiceDescription
    case unsupportedCloneLanguage(String)

    var errorDescription: String? {
        switch self {
        case .missingChatterboxReference:
            return String(localized: "Copying a voice needs a recording to copy it from.")
        case .missingVoiceDescription:
            return String(localized: "Describing a voice needs a description of one.")
        case .unsupportedCloneLanguage(let language):
            return String(localized: "A copied voice cannot speak \(language) yet.")
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
