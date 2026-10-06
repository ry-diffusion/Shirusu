import AVFoundation
import FluidAudio
import Foundation
import Speech

/// Transcription in exactly one language, through Apple's `SpeechTranscriber`.
///
/// Parakeet cannot be told which language it is hearing; it decides per
/// utterance, and a short or mumbled one can come out in the wrong language.
/// `SpeechTranscriber` is the opposite: one model per locale, and nothing but
/// that locale comes out of it. Measured on the Portuguese fixtures, a pass
/// takes 0.1–0.7 s, against Parakeet's 0.13, and runs on this Mac like
/// everything else.
///
/// The price is code-switching. Pinned to Portuguese, "faz commit disso" came
/// back as "faz comitiço": an English word in a Portuguese sentence is heard as
/// Portuguese, which is the whole point of the mode and the reason it is a
/// choice rather than the default.
actor PinnedTranscriber {
    static let shared = PinnedTranscriber()

    /// Where a language stands with Apple's models on this Mac.
    enum Readiness: Equatable, Sendable {
        /// Apple has no model for it.
        case unsupported
        /// Apple has one, not downloaded yet.
        case downloadable(Locale)
        case ready(Locale)
    }

    enum Failure: LocalizedError {
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let name):
                String(localized: "Apple's transcriber has no model for \(name).")
            }
        }
    }

    private var locales: [String: Locale] = [:]

    /// The locale Apple would transcribe `code` in, in the region this Mac
    /// prefers — Brazilian rather than European Portuguese for someone whose
    /// Mac is set to pt-BR — or `nil` when there is none.
    ///
    /// Matched exactly against Apple's list rather than through
    /// `supportedLocale(equivalentTo:)`, which is loose about regions: asked
    /// for French in Brazil it answered Belgium, and for English in Brazil,
    /// New Zealand. Each wrong answer would also spend one of the app's few
    /// model reservations.
    func locale(for code: String) async -> Locale? {
        if let known = locales[code] { return known }
        let asked = Locale(identifier: code)
        let wanted = asked.language.languageCode?.identifier ?? code
        let supported = await SpeechTranscriber.supportedLocales
            .filter { $0.language.languageCode?.identifier == wanted }
        guard !supported.isEmpty else { return nil }

        // In order: the region asked for, the regions this Mac's languages
        // name, the Mac's own region, then where the language is spoken most.
        let regions = ([asked.region]
            + Locale.preferredLanguages.map(Locale.init(identifier:))
                .filter { $0.language.languageCode?.identifier == wanted }
                .map(\.region)
            + [Locale.current.region, Locale.Language(identifier: wanted).maximalIdentifier
                .split(separator: "-").last.map { Locale.Region(String($0)) }])
            .compactMap { $0 }
        let match = regions.lazy.compactMap { region in supported.first { $0.region == region } }.first
            ?? supported.min { $0.identifier < $1.identifier }
        locales[code] = match
        return match
    }

    func readiness(for code: String) async -> Readiness {
        guard let locale = await locale(for: code) else { return .unsupported }
        let status = await AssetInventory.status(forModules: [Self.transcriber(for: locale)])
        return status == .installed ? .ready(locale) : .downloadable(locale)
    }

    /// Downloads Apple's model for `locale` if it is not here yet. The system
    /// keeps it, updates it and shares it with other apps afterwards.
    func install(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        // An app gets a handful of reservations. One for the same language in
        // another region is the one this replaces, so it goes back first.
        for reserved in await AssetInventory.reservedLocales
        where reserved.language.languageCode == locale.language.languageCode
            && reserved.identifier != locale.identifier
        {
            await AssetInventory.release(reservedLocale: reserved)
        }
        // Full, with this one not among them: make room, but never at the
        // expense of the language dictation is held to.
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(locale), reserved.count >= AssetInventory.maximumReservedLocales {
            let kept = LanguagePriorities.shared.onlyLanguage?.rawValue
            if let spare = reserved.first(where: { $0.language.languageCode?.identifier != kept }) {
                await AssetInventory.release(reservedLocale: spare)
            }
        }
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [Self.transcriber(for: locale)])
        else { return }
        let watch = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watch.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    /// One pass over 16 kHz mono samples, the shape the rest of the app keeps.
    func transcribe(_ samples: [Float], language code: String) async throws -> String {
        let words = try await words(samples, language: code)
        return Vocabulary.corrected(TimedWords.text(words))
    }

    /// The same pass, word by word with timings, for subtitles and dubbing.
    func words(_ samples: [Float], language code: String) async throws -> [WordTiming] {
        guard samples.count >= BatchTranscriber.minimumSamples else { return [] }
        guard let locale = await locale(for: code) else {
            throw Failure.unsupported(Locale.current.localizedString(forLanguageCode: code) ?? code)
        }
        let transcriber = Self.transcriber(for: locale)
        // Apple may let go of a model nobody has used in a while, so the
        // check runs every time rather than once at the toggle.
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            try await install(locale)
        }

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            // Kept warm between passes, which is what makes the preview loop
            // and the release pass after it cheap.
            options: .init(priority: .userInitiated, modelRetention: .lingering))
        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
        guard let buffer = AudioDecoder.makeBuffer(samples[...]) else { return [] }
        let inputs = try converter.convert(buffer, at: nil) + converter.flush()
        let (stream, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        for input in inputs { feed.yield(input) }
        feed.finish()

        async let collected = transcriber.results.reduce(into: [WordTiming]()) { words, result in
            words += TimedWords.words(in: result.text)
        }
        if let last = try await analyzer.analyzeSequence(stream) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }

    /// Loads Apple's model once, so the first press does not pay for it.
    func warmUp(language code: String) async {
        guard case .ready = await readiness(for: code) else { return }
        var noise = [Float](repeating: 0, count: BatchTranscriber.minimumSamples)
        for index in noise.indices { noise[index] = Float.random(in: -0.001...0.001) }
        _ = try? await transcribe(noise, language: code)
    }

    private static func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [],
            attributeOptions: [.audioTimeRange])
    }
}

/// Words with timings, from either engine, and the text they make.
nonisolated enum TimedWords {
    /// Apple marks time on runs of text rather than on words. A run that
    /// starts after a space starts a word; one that does not — a comma, the
    /// rest of a word — belongs to the word before it.
    static func words(in text: AttributedString) -> [WordTiming] {
        var words: [WordTiming] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let range = run.audioTimeRange
            let start = range?.start.seconds ?? words.last?.endTime ?? 0
            let end = range?.end.seconds ?? start
            if let last = words.last, piece.first?.isWhitespace == false {
                words[words.count - 1] = WordTiming(
                    word: last.word + trimmed, startTime: last.startTime, endTime: max(last.endTime, end))
            } else {
                words.append(WordTiming(word: trimmed, startTime: start, endTime: end))
            }
        }
        return words
    }

    static func text(_ words: [WordTiming]) -> String {
        words.map(\.word).joined(separator: " ")
    }
}
