import ChatterboxTTS
import FluidAudio
import Foundation
import NaturalLanguage

/// Which voice says a line, and in what language — read from options on the
/// command line or fields in a dub script, which are the same names.
struct VoiceRequest {
    var language: SpeechSession.Language?
    var preset: SpeechSession.Voice = .f1
    var profile: VoiceProfile?
    var description: String?
    var engine: CloningEngine?
    var direction = ""
    var controls = MLXAudioControls()

    /// The app's three modes, chosen by what was asked for.
    var backend: SpeechBackend {
        if profile != nil { return .mlxAudio }
        if description != nil { return .voiceDesign }
        return .supertonic3
    }

    /// The fields a request can be given, on the command line and in a script.
    static let fields = ["language", "voice", "profile", "describe", "engine", "direction", "tone", "pace"]

    /// `fields` laid over `base`, so a segment only says what it changes.
    static func resolve(
        _ fields: [String: String],
        over base: VoiceRequest = VoiceRequest(),
        profiles: VoiceProfiles
    ) throws -> VoiceRequest {
        var request = base
        if let language = fields["language"] {
            request.language = try SpeechSession.Language(argument: language)
        }
        // Each way of naming a voice replaces the others, so a segment that
        // switches to a ready voice is not still cloning the one above it.
        if let voice = fields["voice"] {
            guard let preset = SpeechSession.Voice(rawValue: voice.uppercased()) else {
                throw Failure("“\(voice)” is not a ready voice. They are F1–F5 and M1–M5.", code: 64)
            }
            request.preset = preset
            request.profile = nil
            request.description = nil
        }
        if let name = fields["profile"] {
            request.profile = try profile(named: name, in: profiles)
            request.description = nil
        }
        if let description = fields["describe"] {
            request.description = description
            request.profile = nil
        }
        if let engine = fields["engine"] {
            switch engine.lowercased() {
            case "quick", "chatterbox": request.engine = .quick
            case "detailed", "voxcpm", "voxcpm2": request.engine = .detailed
            default: throw Failure("--engine is quick (Chatterbox) or detailed (VoxCPM2).", code: 64)
            }
        }
        if let direction = fields["direction"] { request.direction = direction }
        if let tone = fields["tone"] {
            guard let value = VoiceLine.Tone(rawValue: tone.lowercased()) else {
                throw Failure("--tone is calm, natural, lively or dramatic.", code: 64)
            }
            request.controls.exaggeration = value.exaggeration
        }
        if let pace = fields["pace"] {
            guard let value = VoiceLine.Pace(rawValue: pace.lowercased()) else {
                throw Failure("--pace is slow, normal or quick.", code: 64)
            }
            request.controls.cfgWeight = value.cfgWeight
        }
        return request
    }

    private static func profile(named name: String, in profiles: VoiceProfiles) throws -> VoiceProfile {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        if let match = profiles.all.first(where: {
            $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                || $0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame
        }) {
            return match
        }
        let known = profiles.all.map { "“\($0.name)”" }.joined(separator: ", ")
        throw Failure(
            known.isEmpty
                ? "No saved voices yet. Record or import one in Shirusu → Text to Speech first."
                : "No saved voice called “\(name)”. Saved: \(known).",
            code: 64)
    }

    /// Ready to hand to the engine: the language settled, and every model it
    /// needs switched on in the app's settings.
    func settled(for text: String, preferences: ModelPreferences) throws -> Settled {
        let language = language ?? Self.language(of: text)
        let cloning = engine ?? preferences.availableCloningEngines.first ?? .quick

        switch backend {
        case .supertonic3 where !preferences.enableSupertonic:
            throw Failure("Ready voices (Supertonic) are switched off in Shirusu → Settings.", code: 69)
        case .mlxAudio where cloning == .quick && !preferences.enableChatterbox:
            throw Failure("Chatterbox is switched off in Shirusu → Settings. Try --engine detailed.", code: 69)
        case .mlxAudio where cloning == .detailed && !preferences.enableVoxCPM,
            .voiceDesign where !preferences.enableVoxCPM:
            throw Failure("VoxCPM2 is switched off in Shirusu → Settings.", code: 69)
        default:
            break
        }
        return Settled(request: self, language: language, cloning: cloning)
    }

    struct Settled {
        let request: VoiceRequest
        let language: SpeechSession.Language
        let cloning: CloningEngine
    }

    /// The language a line is written in, among the ones the voices speak.
    private static func language(of text: String) -> SpeechSession.Language {
        let recogniser = NLLanguageRecognizer()
        recogniser.languageConstraints = SpeechSession.Language.allCases.map { NLLanguage($0.rawValue) }
        recogniser.processString(text)
        return recogniser.dominantLanguage
            .flatMap { SpeechSession.Language(rawValue: $0.rawValue) } ?? .english
    }
}

extension SpeechSession {
    /// One line through whichever engine the request settled on.
    func render(_ text: String, as voice: VoiceRequest.Settled, profiles: VoiceProfiles) async throws -> SpeechTake {
        let progress = ProgressLine()
        return try await render(
            text: text,
            backend: voice.request.backend,
            language: voice.language,
            voice: voice.request.preset,
            mlxAudio: voice.request.controls,
            referenceAudio: voice.request.profile.map { profiles.reference(for: $0.id) },
            cloning: voice.cloning,
            voiceDescription: voice.request.description ?? voice.request.direction,
            progress: { fraction in
                // Reported while the weights are found or fetched; synthesis
                // itself is one call with nothing to report until it returns.
                progress.show("Preparing the voice model", fraction: fraction)
            })
    }
}

extension SpeechSession.Language {
    init(argument: String) throws {
        let code = Locale(identifier: argument.lowercased()).language.languageCode?.identifier
        if let code, let language = Self(rawValue: code) {
            self = language
        } else if let language = Self.allCases.first(where: {
            $0.label.compare(argument, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                || Locale(identifier: "en").localizedString(forLanguageCode: $0.rawValue)?
                    .caseInsensitiveCompare(argument) == .orderedSame
        }) {
            self = language
        } else {
            let known = Self.allCases.map(\.rawValue).joined(separator: ", ")
            throw Failure("The voices do not speak “\(argument)”. They speak \(known).", code: 64)
        }
    }
}

/// `shirusu speak`: one piece of text, one WAV.
enum SpeakCommand {
    static func run(_ arguments: Arguments) async throws {
        try Console.requireRedirectedOutput()

        var text = arguments.value("text") ?? arguments.positionals.joined(separator: " ")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = try StandardInput.text()
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure("Nothing to say.", code: 64) }

        let preferences = ModelPreferences()
        let profiles = VoiceProfiles()
        let fields = arguments.options.filter { VoiceRequest.fields.contains($0.key) }
        let voice = try VoiceRequest.resolve(fields, profiles: profiles)
            .settled(for: text, preferences: preferences)

        Console.note("Speaking in \(voice.language.label)…")
        let take = try await SpeechSession().render(text, as: voice, profiles: profiles)

        var samples = take.samples
        var rate = take.sampleRate
        if let wanted = try arguments.number("sample-rate").map(Int.init), wanted != rate {
            samples = AudioTools.resample(samples, from: rate, to: wanted)
            rate = wanted
        }
        Console.write(WavEncoder.data(samples: samples, sampleRate: rate))
        Console.note(String(format: "%.1f s of audio.", Double(samples.count) / Double(rate)))
    }
}

/// `shirusu voices`: what there is to speak with, as JSON.
enum VoicesCommand {
    private struct Listing: Encodable {
        struct Profile: Encodable {
            let name: String
            let id: String
            let seconds: Double
            let checked: Bool?
        }

        struct Engines: Encodable {
            let supertonic: Bool
            let chatterbox: Bool
            let voxcpm: Bool
        }

        let presets: [String]
        let profiles: [Profile]
        let engines: Engines
        /// What ready voices and VoxCPM2 speak.
        let speechLanguages: [String]
        /// What Chatterbox can copy a voice into.
        let quickCloneLanguages: [String]
        /// What the transcriber hears, and the saved priorities.
        let listeningLanguages: [String]
        let languagePriorities: [String]
    }

    static func run(_ arguments: Arguments) async throws {
        let preferences = ModelPreferences()
        let profiles = VoiceProfiles()
        let listing = Listing(
            presets: SpeechSession.Voice.allCases.map(\.rawValue),
            profiles: profiles.all.map {
                .init(
                    name: $0.name, id: $0.id.uuidString,
                    seconds: ($0.duration * 10).rounded() / 10, checked: $0.check?.isGood)
            },
            engines: .init(
                supertonic: preferences.enableSupertonic,
                chatterbox: preferences.enableChatterbox,
                voxcpm: preferences.enableVoxCPM),
            speechLanguages: SpeechSession.Language.allCases.map(\.rawValue),
            quickCloneLanguages: MTLTokenizer.supportedLanguages.sorted(),
            listeningLanguages: LanguagePriorities.supported.map(\.rawValue),
            languagePriorities: LanguagePriorities.shared.ordered.map(\.rawValue))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        Console.write(try encoder.encode(listing))
        Console.write("\n")
    }
}

/// `shirusu languages [codes…]`: read or set the dictation priorities.
enum LanguagesCommand {
    static func run(_ arguments: Arguments) throws {
        if !arguments.positionals.isEmpty {
            let languages = try Language.list(arguments.positionals.joined(separator: ","))
            LanguagePriorities.shared.replace(with: languages)
            Console.note("Saved. Shirusu picks this up the next time it opens.")
        }
        let ordered = LanguagePriorities.shared.ordered
        guard !ordered.isEmpty else { return Console.print("(none: any alphabet)") }
        for (index, language) in ordered.enumerated() {
            let pin = index == 0 ? "  (pinned)" : ""
            Console.print("\(index + 1). \(language.rawValue)  \(LanguagePriorities.name(of: language))\(pin)")
        }
    }
}
