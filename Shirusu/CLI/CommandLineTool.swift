import FluidAudio
import Foundation

/// `Shirusu --cli <command>`: the app's engines, without the app.
///
/// Everything the sandbox would refuse is moved to the shell's side of the
/// line. Input arrives on stdin, results leave on stdout, and progress and
/// warnings go to stderr, so `shirusu dub < script.json > dub.wav` works with
/// nothing but the file descriptors the shell already opened.
enum CommandLineTool {
    static let flag = "--cli"

    /// The real stdout, kept aside for results.
    ///
    /// fd 1 itself is pointed at stderr before any work starts. The model
    /// libraries print as they please, and one stray line in the middle of a
    /// WAV is a corrupt file; this way their chatter lands on the terminal and
    /// only what this tool means to write reaches the output.
    /// Set once, before anything else runs, and only read afterwards.
    nonisolated(unsafe) private(set) static var output = FileHandle.standardOutput

    static func start(_ arguments: [String]) {
        let saved = dup(STDOUT_FILENO)
        if saved >= 0 {
            output = FileHandle(fileDescriptor: saved, closeOnDealloc: true)
            dup2(STDERR_FILENO, STDOUT_FILENO)
        }

        Task {
            let code: Int32
            do {
                try await run(Arguments(arguments))
                code = 0
            } catch let failure as Failure {
                Console.error(failure.message)
                code = failure.code
            } catch {
                Console.error(error.localizedDescription)
                code = 1
            }
            try? output.synchronize()
            exit(code)
        }
    }

    private static func run(_ arguments: Arguments) async throws {
        var arguments = arguments
        let command = arguments.positionals.isEmpty ? "help" : arguments.positionals.removeFirst()
        if arguments.flags.contains("help") { return Console.print(usage) }

        switch command {
        case "transcribe": try await TranscribeCommand.run(arguments)
        case "speak": try await SpeakCommand.run(arguments)
        case "dub": try await DubCommand.run(arguments)
        case "voices": try await VoicesCommand.run(arguments)
        case "languages": try await LanguagesCommand.run(arguments)
        case "help", "-h": Console.print(usage)
        default: throw Failure("Unknown command “\(command)”.\n\n\(usage)", code: 64)
        }
    }

    static let usage = """
        shirusu — Shirusu's transcription and voices, from the terminal.

        USAGE
          shirusu transcribe <audio-or-video> [--format text|json|srt|vtt] [--language pt,en | --only pt-BR]
          shirusu speak "text" -o out.wav [--language en] [--voice F1 | --profile NAME | --describe TEXT]
          shirusu dub script.json -o dub.wav [--max-speed 1.25] [--sample-rate 48000] [--report]
          shirusu voices
          shirusu languages [pt en ...] [--release-models]

        TRANSCRIBE
          Reads any file macOS can decode, video included. --format json gives
          timed segments, which is what `dub` takes after translation.
          --language overrides the saved \u{201C}Languages I speak\u{201D} for this run.
          --only uses Apple's transcriber held to one language instead: nothing
          else comes out, and it also covers ja, ko and zh. It downloads Apple's
          model for the language the first time.

        SPEAK
          Text comes from the arguments, --text, or stdin. Voices:
            --voice F1…F5, M1…M5      a ready voice (Supertonic)
            --profile NAME            a voice saved in the app, copied
              --engine quick|detailed   Chatterbox or VoxCPM2 (default quick)
              --direction TEXT          a delivery note, detailed engine only
              --tone calm|natural|lively|dramatic, --pace slow|normal|quick
            --describe TEXT           a voice built from a description (VoxCPM2)

        DUB
          Renders a timed script into one track, each line starting where its
          segment starts. A line too long for its slot is sped up, pitch kept,
          up to --max-speed; anything still too long is reported on stderr.
          The script:
            { "language": "en", "voice": "F2", "duration": 61.5,
              "segments": [ { "start": 0.4, "end": 3.1, "text": "Hello." } ] }
          Every voice option above works at the top level and per segment
          (voice, profile, describe, engine, direction, tone, pace, language).

        VOICES / LANGUAGES
          voices lists ready voices, saved profiles and enabled engines as JSON.
          languages shows the dictation language priorities, or sets them, and
          which of Apple's language models (--only) the app holds. An app may
          hold only a few; --release-models frees all but dictation's.

        Audio is always WAV. Files go in and out through the `shirusu` script,
        which turns paths into stdin and stdout so the app can stay sandboxed.
        """
}

/// A failure worth a sentence and an exit code, rather than a stack of errors.
nonisolated struct Failure: Error {
    let message: String
    let code: Int32

    init(_ message: String, code: Int32 = 1) {
        self.message = message
        self.code = code
    }
}

/// `--key value`, `--key=value`, bare flags and positionals.
struct Arguments {
    var positionals: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    /// The options that never take a value. Anything else does.
    private static let switches: Set<String> = ["help", "report", "quiet", "release-models"]

    init(_ raw: [String]) {
        var index = raw.startIndex
        while index < raw.endIndex {
            let item = raw[index]
            index += 1
            // `-Key value` is a defaults override for this process, which
            // Foundation reads by itself — not words to say or a file.
            if item.count > 1, item.hasPrefix("-"), !item.hasPrefix("--"),
                item.dropFirst().first?.isLetter == true, index < raw.endIndex
            {
                index += 1
                continue
            }
            guard item.hasPrefix("--"), item.count > 2 else {
                positionals.append(item)
                continue
            }
            let body = String(item.dropFirst(2))
            if let equals = body.firstIndex(of: "=") {
                options[String(body[..<equals])] = String(body[body.index(after: equals)...])
            } else if Self.switches.contains(body) || index == raw.endIndex {
                flags.insert(body)
            } else {
                options[body] = raw[index]
                index += 1
            }
        }
    }

    func value(_ name: String) -> String? {
        options[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    func number(_ name: String) throws -> Double? {
        guard let text = value(name) else { return nil }
        guard let number = Double(text) else {
            throw Failure("--\(name) wants a number, not “\(text)”.", code: 64)
        }
        return number
    }
}

/// stderr for people, the saved stdout for results.
nonisolated enum Console {
    nonisolated(unsafe) static var isQuiet = false

    static func print(_ text: String) {
        write(text + "\n")
    }

    static func write(_ text: String) {
        CommandLineTool.output.write(Data(text.utf8))
    }

    static func write(_ data: Data) {
        CommandLineTool.output.write(data)
    }

    static func note(_ text: String) {
        guard !isQuiet else { return }
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data(("shirusu: " + text + "\n").utf8))
    }

    /// Whether the results are about to scroll past on a terminal.
    static var outputIsTerminal: Bool {
        isatty(CommandLineTool.output.fileDescriptor) == 1
    }

    /// Audio has nowhere useful to go on a terminal, and a screen of binary
    /// is a bad way to find that out.
    static func requireRedirectedOutput() throws {
        guard !outputIsTerminal else {
            throw Failure("This writes a WAV file. Give it -o file.wav, or redirect stdout.", code: 64)
        }
    }
}

/// Everything waiting on stdin, which for the commands that read a file is
/// that file, redirected by the `shirusu` script.
enum StandardInput {
    static func data() throws -> Data {
        guard isatty(STDIN_FILENO) == 0 else {
            throw Failure("Nothing on stdin. Pass a file, or pipe one in.", code: 66)
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else { throw Failure("stdin was empty.", code: 66) }
        return data
    }

    static func text() throws -> String {
        guard let text = String(data: try data(), encoding: .utf8) else {
            throw Failure("stdin is not UTF-8 text.", code: 65)
        }
        return text
    }

    /// stdin written into the container's temporary folder, under a name the
    /// decoders recognise. AVFoundation reads a container by its extension as
    /// much as by its bytes, so the bytes are sniffed when no name was given.
    static func file(named name: String?) throws -> URL {
        let data = try data()
        let suffix = name.map { URL(fileURLWithPath: $0).pathExtension }.flatMap { $0.isEmpty ? nil : $0 }
            ?? sniffedExtension(data)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shirusu-cli-\(UUID().uuidString)")
            .appendingPathExtension(suffix)
        try data.write(to: url)
        return url
    }

    private static func sniffedExtension(_ data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes
        }
        if starts(Array("RIFF".utf8)) { return "wav" }
        if starts(Array("ftyp".utf8), at: 4) { return "mp4" }
        if starts(Array("OggS".utf8)) { return "ogg" }
        if starts(Array("fLaC".utf8)) { return "flac" }
        if starts(Array("caff".utf8)) { return "caf" }
        if starts(Array("FORM".utf8)) { return "aiff" }
        if starts(Array("ID3".utf8)) || starts([0xFF]) { return "mp3" }
        if starts([0x1A, 0x45, 0xDF, 0xA3]) { return "mkv" }
        return "audio"
    }
}

extension Language {
    /// `pt`, `pt-BR`, `Portuguese` and `português` all mean the same thing on
    /// a command line.
    init?(argument: String) {
        let lowered = argument.lowercased().trimmingCharacters(in: .whitespaces)
        if let code = Locale(identifier: lowered).language.languageCode?.identifier,
            let language = Language(rawValue: code)
        {
            self = language
            return
        }
        guard let match = LanguagePriorities.supported.first(where: { language in
            [Locale(identifier: "en"), Locale(identifier: language.rawValue), Locale.current]
                .compactMap { $0.localizedString(forLanguageCode: language.rawValue)?.lowercased() }
                .contains(lowered)
        }) else { return nil }
        self = match
    }

    static func list(_ argument: String) throws -> [Language] {
        try argument
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { item in
                guard let language = Language(argument: String(item)) else {
                    throw Failure("“\(item)” is not a language Shirusu can hear.", code: 64)
                }
                return language
            }
    }
}
