import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import Shirusu

/// Locates the test bundle's resources.
private final class BundleToken {}
private let testBundle = Bundle(for: BundleToken.self)

private func fixture(_ name: String, _ ext: String) throws -> URL {
    try #require(
        testBundle.url(forResource: name, withExtension: ext),
        "fixture \(name).\(ext) is missing from the test bundle"
    )
}

// MARK: - Transcript

@MainActor
struct TranscriptTests {
    @Test("Confirmed and volatile text become one flow of words")
    func combinesBothHalves() {
        let transcript = Transcript()
        transcript.apply(confirmed: "boa tarde isso é", volatile: "um teste")

        #expect(transcript.words.map(\.text) == ["boa", "tarde", "isso", "é", "um", "teste"])
        #expect(transcript.words.filter(\.isSettled).count == 4)
        #expect(transcript.plainText == "boa tarde isso é um teste")
    }

    @Test("A word that has not changed keeps its identity, so it does not re-animate")
    func stableIdentityForUnchangedWords() {
        let transcript = Transcript()
        transcript.apply(confirmed: "boa tarde", volatile: "isso")
        let before = transcript.words.map(\.id)

        transcript.apply(confirmed: "boa tarde isso", volatile: "é um teste")
        let after = transcript.words.map(\.id)

        #expect(Array(after.prefix(2)) == Array(before.prefix(2)))
        #expect(transcript.words.count == 6)
    }

    @Test("A word promoted from volatile to confirmed keeps its identity")
    func promotionKeepsIdentity() {
        let transcript = Transcript()
        transcript.apply(confirmed: "", volatile: "talvez")
        let id = transcript.words[0].id
        #expect(transcript.words[0].isSettled == false)

        transcript.apply(confirmed: "talvez", volatile: "")
        #expect(transcript.words[0].id == id)
        #expect(transcript.words[0].isSettled)
    }

    @Test("A revised hypothesis replaces only the words that actually changed")
    func revisionRestartsAtTheDivergence() {
        let transcript = Transcript()
        transcript.apply(confirmed: "o modelo", volatile: "erra as vezes")
        let kept = transcript.words[0].id

        transcript.apply(confirmed: "o modelo", volatile: "acerta sempre")
        #expect(transcript.words[0].id == kept)
        #expect(transcript.words.map(\.text) == ["o", "modelo", "acerta", "sempre"])
    }

    @Test("Resetting clears everything")
    func resetClears() {
        let transcript = Transcript()
        transcript.apply(confirmed: "alguma coisa", volatile: "")
        transcript.reset()
        #expect(transcript.isEmpty)
        #expect(transcript.plainText.isEmpty)
    }
}

// MARK: - Audio decoding

struct AudioDecoderTests {
    @Test("A compressed file decodes to the 16 kHz mono the models require")
    func decodesToModelFormat() async throws {
        let decoded = try await AudioDecoder.decode(try fixture("speech-pt", "m4a"))

        #expect(decoded.samples.count > 0)
        // The fixture is about fifteen seconds of speech.
        #expect(decoded.duration > 10 && decoded.duration < 20)
        // Real speech, not silence.
        #expect(decoded.samples.contains { abs($0) > 0.01 })
    }

    @Test("Decoded samples wrap into a buffer the recogniser accepts")
    func wrapsIntoBuffer() async throws {
        let decoded = try await AudioDecoder.decode(try fixture("speech-pt", "m4a"))
        let slice = decoded.samples[0..<min(AudioFormats.chunkFrames, decoded.samples.count)]
        let buffer = try #require(AudioDecoder.makeBuffer(slice))

        #expect(buffer.format.sampleRate == 16_000)
        #expect(buffer.format.channelCount == 1)
        #expect(Int(buffer.frameLength) == slice.count)
    }

    @Test("An unreadable file fails with a message worth showing")
    func failsLoudly() async throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("shirusu-not-audio.wav")
        try Data("this is not audio".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }

        await #expect(throws: AudioDecoderError.self) {
            _ = try await AudioDecoder.decode(bogus)
        }
    }
}

// MARK: - File feed

struct FileFeedTests {
    @Test("The fast pace streams the whole file in 16 kHz chunks")
    func streamsEveryChunk() async throws {
        let feed = try await FileFeed.load(url: try fixture("speech-pt", "m4a"), pace: .fast)
        let expected = try #require(feed.duration)

        var chunks = 0
        var frames = 0
        var lastPosition: TimeInterval = -1

        for try await chunk in feed.chunks() {
            chunks += 1
            frames += Int(chunk.buffer.frameLength)
            // Positions must advance, or the progress readout lies.
            #expect(chunk.position > lastPosition)
            lastPosition = chunk.position
            #expect(chunk.buffer.format.sampleRate == 16_000)
        }

        #expect(chunks > 1)
        let streamed = Double(frames) / Double(AudioFormats.sampleRate)
        #expect(abs(streamed - expected) < 0.01)
    }
}

// MARK: - The whole pipeline

/// Runs a real file through the real recogniser. Skipped when the Nemotron
/// bundle has not been downloaded yet, so a clean checkout still passes.
@MainActor
struct TranscriptionPipelineTests {
    @Test(
        "A file streams end to end and comes out as settled text",
        .enabled(if: ShirusuModel.isInstalled),
        .timeLimit(.minutes(2))
    )
    func transcribesAFile() async throws {
        let models = try await ModelSetup.prepare { _, _ in }
        let session = TranscriptionSession(engine: BatchTranscriber(models: models), profile: .live)
        let feed = try await FileFeed.load(url: try fixture("speech-pt", "m4a"), pace: .fast)

        session.start(feed)
        try await waitUntil { session.phase == .idle && !session.transcript.isEmpty }

        let text = session.transcript.plainText
        // Printed so a failing run shows what the model actually heard.
        print("TRANSCRIPT >>> \(text)")
        #expect(!text.isEmpty)
        // The fixture says "transcrição"; if the model heard anything at all,
        // some of these will be there.
        let heard = ["teste", "transcrição", "Mac", "modelo", "tempo"]
            .filter { text.localizedCaseInsensitiveContains($0) }
        #expect(!heard.isEmpty, "nothing recognisable in: \(text)")

        // Once finished, nothing may still be marked as in-flight.
        let stillInFlight = session.transcript.words.filter { !$0.isSettled }
        #expect(stillInFlight.isEmpty)
        #expect(session.position > 0)
    }

    /// Polls on the main actor until `condition` holds or the deadline passes.
    private func waitUntil(
        timeout: Duration = .seconds(100),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("timed out waiting for the pipeline to settle")
    }
}

/// Measures the shape a push-to-talk hotkey uses: hold the key, buffer the
/// audio, hand the whole utterance over on release.
@MainActor
struct WholeUtteranceThroughputTests {
    @Test(
        "Whole-utterance throughput",
        .enabled(if: ShirusuModel.isInstalled),
        .timeLimit(.minutes(2))
    )
    func measuresRealTimeFactor() async throws {
        let models = try await ModelSetup.prepare { _, _ in }
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)

        let decoded = try await AudioDecoder.decode(try fixture("speech-pt", "m4a"))
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)

        let started = ContinuousClock.now
        let result = try await asr.transcribe(decoded.samples, decoderState: &state)
        let elapsed = ContinuousClock.now - started
        let seconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        print(
            String(
                format: "UTTERANCE >>> %.2fs of audio in %.3fs = %.0fx realtime | %@",
                decoded.duration, seconds, decoded.duration / seconds, result.text
            )
        )
        #expect(!result.text.isEmpty)
    }
}

/// The question a push-to-talk hotkey actually raises: while you are still
/// holding the key, do words appear, and how far behind your voice are they?
///
/// Feeds the fixture at true speed and timestamps the first appearance of each
/// word, so the cadence is measured rather than asserted.
@MainActor
struct DictationCadenceTests {
    @Test(
        "Words land while the audio is still playing",
        .enabled(if: ShirusuModel.isInstalled),
        .timeLimit(.minutes(5))
    )
    func measuresCadence() async throws {
        let models = try await ModelSetup.prepare { _, _ in }

        for profile in [ShirusuModel.Profile.live, .pushToTalk] {
            let session = TranscriptionSession(engine: BatchTranscriber(models: models), profile: profile)
            let feed = try await FileFeed.load(
                url: try fixture("speech-pt", "m4a"), pace: .realtime)
            let total = try #require(feed.duration)

            var arrivals: [Double] = []
            let started = ContinuousClock.now
            session.start(feed)

            while true {
                let now = ContinuousClock.now - started
                let elapsed =
                    Double(now.components.seconds) + Double(now.components.attoseconds) / 1e18

                let count = session.transcript.words.count
                while arrivals.count < count { arrivals.append(elapsed) }

                if session.phase == .idle, !arrivals.isEmpty { break }
                if elapsed > total + 30 { break }
                try await Task.sleep(for: .milliseconds(20))
            }

            // Only count words that showed up before the audio ran out; anything
            // after that is the flush, not live feedback.
            let live = arrivals.filter { $0 < total }
            let gaps = zip(live, live.dropFirst()).map { $1 - $0 }.filter { $0 > 0.01 }
            let meanGap = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)

            print(
                String(
                    format:
                        "CADENCE [%@] first word %.2fs | %d of %d words during playback | %.2f words/s | worst gap %.2fs",
                    String(describing: profile),
                    live.first ?? -1,
                    live.count,
                    arrivals.count,
                    live.count > 1 ? Double(live.count - 1) / (live.last! - live.first!) : 0,
                    gaps.max() ?? 0
                )
            )
            _ = meanGap
            #expect(!arrivals.isEmpty)
        }
    }
}
