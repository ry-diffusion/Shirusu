import AVFoundation
import AudioCommon
import Foundation

/// `shirusu dub`: a timed script in, one voice track out.
///
/// Each line starts where its segment starts. That is the half of lip-sync a
/// listener notices first, and the only half a voice model can be held to: it
/// says a line at its own pace, so the end is managed rather than matched. A
/// line may run on into the silence after it; one that would run into the next
/// line is sped up, pitch kept, as far as `--max-speed` allows, and whatever
/// is still too long is reported so the line can be rewritten shorter.
enum DubCommand {
    /// A dub script. Every voice field works at both levels; a segment's
    /// fields win over the script's.
    private struct Script: Decodable {
        var duration: Double?
        var segments: [Segment]
        var voice: Fields

        struct Segment {
            var id: Int?
            var start: Double
            var end: Double?
            var text: String
            var voice: Fields
        }

        typealias Fields = [String: String]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            duration = try container.decodeIfPresent(Double.self, forKey: Key("duration"))
            voice = try Self.fields(in: container)
            var list = try container.nestedUnkeyedContainer(forKey: Key("segments"))
            segments = []
            while !list.isAtEnd {
                let item = try list.nestedContainer(keyedBy: Key.self)
                segments.append(Segment(
                    id: try item.decodeIfPresent(Int.self, forKey: Key("id")),
                    start: try item.decode(Double.self, forKey: Key("start")),
                    end: try item.decodeIfPresent(Double.self, forKey: Key("end")),
                    text: try item.decode(String.self, forKey: Key("text")),
                    voice: try Self.fields(in: item)))
            }
        }

        private static func fields(in container: KeyedDecodingContainer<Key>) throws -> Fields {
            var fields: Fields = [:]
            for name in VoiceRequest.fields {
                if let value = try container.decodeIfPresent(String.self, forKey: Key(name)),
                    !value.isEmpty
                {
                    fields[name] = value
                }
            }
            return fields
        }

        struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(_ string: String) { stringValue = string }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
    }

    /// How one line landed.
    private struct Fit: Encodable {
        let id: Int
        let start: Double
        /// Seconds from this line's start to the next one's, or to the end.
        let room: Double
        /// Seconds of speech once silence was trimmed, before any speed-up.
        let spoken: Double
        let speed: Double
        /// Seconds still spilling into the next line after the speed-up.
        let overflow: Double
    }

    /// A breath between one line ending and the next starting.
    private static let gap = 0.08

    static func run(_ arguments: Arguments) async throws {
        try Console.requireRedirectedOutput()
        let maxSpeed = try arguments.number("max-speed") ?? 1.25
        guard (1...2).contains(maxSpeed) else {
            throw Failure("--max-speed is between 1 (never) and 2.", code: 64)
        }
        let rate = try arguments.number("sample-rate").map(Int.init) ?? 48_000

        let script: Script
        do {
            script = try JSONDecoder().decode(Script.self, from: try StandardInput.data())
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure("The script is not valid: \(Self.describe(error))", code: 65)
        }
        let segments = script.segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        guard !segments.isEmpty else { throw Failure("The script has no lines to say.", code: 65) }

        let preferences = ModelPreferences()
        let profiles = VoiceProfiles()
        let base = try VoiceRequest.resolve(script.voice, profiles: profiles)
        let speech = SpeechSession()

        var track: [Float] = []
        var fits: [Fit] = []
        for (index, segment) in segments.enumerated() {
            let id = segment.id ?? index + 1
            let voice = try VoiceRequest.resolve(segment.voice, over: base, profiles: profiles)
                .settled(for: segment.text, preferences: preferences)
            Console.note("[\(index + 1)/\(segments.count)] \(Timecode.vtt(segment.start))  \(segment.text.prefix(60))")

            let take: SpeechSession.SpeechTake
            do {
                take = try await speech.render(segment.text, as: voice, profiles: profiles)
            } catch {
                throw Failure("Line \(id) could not be spoken: \(error.localizedDescription)")
            }
            var samples = AudioTools.trimSilence(
                AudioTools.resample(take.samples, from: take.sampleRate, to: rate), sampleRate: rate)
            let spoken = Double(samples.count) / Double(rate)

            let next = segments.indices.contains(index + 1) ? segments[index + 1].start : nil
            let limit = next.map { $0 - gap } ?? script.duration ?? .infinity
            let room = max(0.1, limit - segment.start)

            var speed = 1.0
            if spoken > room {
                speed = min(maxSpeed, spoken / room)
                samples = try AudioTools.speedUp(samples, sampleRate: rate, by: speed)
            }
            let landed = Double(samples.count) / Double(rate)
            let overflow = max(0, landed - room)
            if overflow > 0.05 {
                Console.note(String(
                    format: "  ⚠︎ line %d runs %.2f s into the next even at %.2f× — shorten it.",
                    id, overflow, speed))
            } else if speed > 1.001 {
                Console.note(String(format: "  sped up %.2f× to fit", speed))
            }

            AudioTools.mix(samples, into: &track, at: Int(segment.start * Double(rate)))
            fits.append(Fit(
                id: id, start: segment.start, room: room.isFinite ? Self.rounded(room) : -1,
                spoken: Self.rounded(spoken), speed: Self.rounded(speed), overflow: Self.rounded(overflow)))
        }

        if let duration = script.duration {
            let wanted = Int(duration * Double(rate))
            if track.count < wanted { track += [Float](repeating: 0, count: wanted - track.count) }
        }
        Console.write(WavEncoder.data(samples: track, sampleRate: rate))

        let late = fits.filter { $0.overflow > 0.05 }
        Console.note(late.isEmpty
            ? "Done: \(fits.count) lines, all in time."
            : "Done: \(fits.count) lines, \(late.count) too long (ids \(late.map { String($0.id) }.joined(separator: ", "))).")
        if arguments.flags.contains("report") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let report = try encoder.encode(["fits": fits])
            FileHandle.standardError.write(report + Data("\n".utf8))
        }
    }

    private static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "“\(key.stringValue)” is missing at \(path(context))."
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "\(context.debugDescription) at \(path(context))."
        case DecodingError.dataCorrupted(let context):
            return context.debugDescription
        default:
            return error.localizedDescription
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        return path.isEmpty ? "the top level" : path
    }
}

/// The few things a dub does to audio between the voice and the file.
nonisolated enum AudioTools {
    static func resample(_ samples: [Float], from source: Int, to target: Int) -> [Float] {
        guard source != target, !samples.isEmpty else { return samples }
        return AudioFileLoader.resample(samples, from: source, to: target, quality: .mastering)
    }

    /// Off both ends, keeping a little air. Voice models pad generously, and
    /// that padding is time a line could have used to fit.
    static func trimSilence(_ samples: [Float], sampleRate: Int) -> [Float] {
        let window = max(1, sampleRate / 100)
        let threshold: Float = 0.006  // about -44 dBFS
        func loud(_ start: Int) -> Bool {
            let end = min(samples.count, start + window)
            guard start < end else { return false }
            var sum: Float = 0
            for index in start..<end { sum += samples[index] * samples[index] }
            return (sum / Float(end - start)).squareRoot() > threshold
        }
        var first = 0
        while first < samples.count, !loud(first) { first += window }
        var last = samples.count
        while last > first, !loud(max(first, last - window)) { last -= window }
        guard first < last else { return [] }
        let air = sampleRate * 3 / 100
        return Array(samples[max(0, first - air)..<min(samples.count, last + air)])
    }

    /// Faster by `rate`, pitch unchanged, through the same time-stretch unit
    /// AVFoundation uses for playback speed.
    static func speedUp(_ samples: [Float], sampleRate: Int, by rate: Double) throws -> [Float] {
        guard rate > 1.001, !samples.isEmpty else { return samples }
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let stretch = AVAudioUnitTimePitch()
        stretch.rate = Float(rate)
        engine.attach(player)
        engine.attach(stretch)
        engine.connect(player, to: stretch, format: format)
        engine.connect(stretch, to: engine.mainMixerNode, format: format)

        let chunk: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
        try engine.start()
        defer { engine.stop() }

        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk)
        else { return samples }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        player.scheduleBuffer(input)
        player.play()

        // The unit has latency, so render a little past the arithmetic and
        // let the trim take back the tail.
        let wanted = Int(Double(samples.count) / rate) + sampleRate / 5
        var result: [Float] = []
        result.reserveCapacity(wanted)
        var stalls = 0
        while result.count < wanted, stalls < 64 {
            let frames = min(chunk, AVAudioFrameCount(wanted - result.count))
            switch try engine.renderOffline(frames, to: output) {
            case .success:
                result.append(contentsOf: UnsafeBufferPointer(
                    start: output.floatChannelData![0], count: Int(output.frameLength)))
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                stalls += 1
            case .error:
                throw Failure("The speed-up failed while rendering.")
            @unknown default:
                throw Failure("The speed-up failed while rendering.")
            }
        }
        return trimSilence(result, sampleRate: sampleRate)
    }

    /// Adds `samples` into `track` at `offset`, growing it as needed.
    static func mix(_ samples: [Float], into track: inout [Float], at offset: Int) {
        let offset = max(0, offset)
        if track.count < offset + samples.count {
            track += [Float](repeating: 0, count: offset + samples.count - track.count)
        }
        for (index, sample) in samples.enumerated() { track[offset + index] += sample }
    }
}
