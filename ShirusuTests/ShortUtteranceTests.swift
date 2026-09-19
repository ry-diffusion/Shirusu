import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import Shirusu

/// What a hotkey actually gets most of the time: one or two seconds of speech.
///
/// The streaming loop only emits once `chunkSeconds + rightContextSeconds` of
/// audio has arrived, so an utterance shorter than that produces nothing live
/// and everything on release. This measures both halves of that.
@MainActor
struct ShortUtteranceTests {
    private final class BundleToken {}

    private func fixture(_ name: String) throws -> URL {
        try #require(
            Bundle(for: BundleToken.self).url(forResource: name, withExtension: "m4a"),
            "missing fixture \(name).m4a"
        )
    }

    @Test(
        "Short utterances: live preview versus the text that gets inserted",
        .enabled(if: ShirusuModel.isInstalled),
        .timeLimit(.minutes(5))
    )
    func shortClips() async throws {
        let models = try await ModelSetup.prepare { _, _ in }
        // One session for the run, as the app has: the CTC head and the
        // pre-warmed manager are paid for once, not per utterance.
        let session = TranscriptionSession(models: models, profile: .pushToTalk)

        for name in ["speech-tiny", "speech-short", "speech-pt"] {
            session.clear()
            let feed = try await FileFeed.load(url: try fixture(name), pace: .realtime)
            let total = try #require(feed.duration)

            var firstWordAt = -1.0
            var previewAtRelease = ""
            let started = ContinuousClock.now
            session.start(feed)

            while true {
                let now = Self.since(started)
                if firstWordAt < 0, !session.transcript.isEmpty { firstWordAt = now }
                // The moment the audio runs out is when a real key would be released.
                if previewAtRelease.isEmpty, now >= total {
                    previewAtRelease = session.transcript.plainText
                }
                if session.phase == .idle, !session.transcript.isEmpty { break }
                if now > total + 30 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let settledAt = Self.since(started)

            print(
                String(
                    format: "SHORT [%@] %.2fs audio | first word %.2fs | release+%.0fms",
                    name, total, firstWordAt, (settledAt - total) * 1000
                )
            )
            print("        preview at release: \(previewAtRelease.isEmpty ? "(nothing)" : previewAtRelease)")
            print("        inserted:           \(session.transcript.plainText)")
            #expect(!session.transcript.isEmpty)
        }
    }

    private static func since(_ start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
