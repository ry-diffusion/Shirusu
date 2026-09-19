import FluidAudio
import Foundation
import OSLog

/// Which model Shirusu runs on, and how it is driven for each job.
///
/// Parakeet TDT v3: 25 languages, and unlike the streaming models it keeps
/// punctuation and capitalisation in Portuguese, including English terms dropped
/// mid-sentence. Measured here, not assumed.
nonisolated enum ShirusuModel {
    static let version: AsrModelVersion = .v3

    /// Script hint for the decoder.
    ///
    /// This filters candidate tokens by *writing system*, not by language: with
    /// Portuguese set, top-K tokens outside the Latin script lose to ones inside
    /// it. English is Latin too, so "commit" and "BMW" are unaffected — which is
    /// the whole reason it is safe to pin. What it does buy is that the decoder
    /// stops drifting into Cyrillic or Greek on unclear audio.
    static let language: Language? = .portuguese

    /// The two jobs have opposite shapes, so they get opposite windows.
    enum Profile: Sendable, CaseIterable {
        /// A window left open. Long sessions, so it takes the proven 2+11+2
        /// layout: confirmations are slower but the text settles correctly.
        case live

        /// Push-to-talk. Utterances last seconds, so waiting ten seconds of
        /// context before confirming anything would mean nothing ever confirms.
        /// Shorter hypotheses, earlier confirmation, smaller window to encode.
        case pushToTalk

        var config: SlidingWindowAsrConfig {
            switch self {
            case .live:
                return .streaming
            case .pushToTalk:
                // The decode loop emits nothing until `chunkSeconds +
                // rightContextSeconds` of audio has arrived, so that sum is the
                // time to the first word on screen. Measured on Portuguese:
                //
                //   1.0 + 0.5 -> 1.6 s
                //   2.0 + 1.0 -> 3.0 s
                //   3.0 + 1.0 -> 4.0 s
                //
                // Small chunks shatter the window seams ("usa.uzu, usando"),
                // which is why this used to sit at 3 + 1. That reason is gone:
                // the text the user keeps now comes from the release pass over
                // the whole utterance, so this stream is a progress indicator
                // and nothing else. Its seams cost nothing, so take the floor.
                return SlidingWindowAsrConfig(
                    chunkSeconds: 1.0,
                    hypothesisChunkSeconds: 1.0,  // stored but unused by the engine
                    leftContextSeconds: 2.0,
                    rightContextSeconds: 0.5,
                    // Counts total audio heard, not a rolling window. At the
                    // stock 10 s a five-second utterance would never confirm.
                    minContextForConfirmation: 1.0,
                    confirmationThreshold: 0.80
                )
            }
        }
    }

    static var installDirectory: URL { AsrModels.defaultCacheDirectory(for: version) }

    static var isInstalled: Bool {
        AsrModels.modelsExist(at: installDirectory, version: version)
    }
}

/// Fetches and compiles the CoreML bundles, reporting where it is along the way.
enum ModelSetup {
    /// The stages a first run actually passes through, in order.
    enum Step: Equatable, Sendable {
        case checking
        case listing
        case downloading(completed: Int, total: Int)
        case compiling(model: String)
        case loading
    }

    private static let log = Logger(subsystem: "br.com.zesmoi.Shirusu", category: "models")

    static func prepare(
        onStep: @escaping @Sendable (Step, Double) -> Void
    ) async throws -> AsrModels {
        onStep(.checking, 0)

        let models = try await AsrModels.downloadAndLoad(
            version: ShirusuModel.version,
            progressHandler: { progress in
                let step: Step
                switch progress.phase {
                case .listing:
                    step = .listing
                case .downloading(let completed, let total):
                    step = .downloading(completed: completed, total: total)
                case .compiling(let name):
                    step = .compiling(model: name)
                }
                onStep(step, progress.fractionCompleted)
            }
        )

        onStep(.loading, 1)
        log.info("Parakeet ready at \(ShirusuModel.installDirectory.path, privacy: .public)")
        return models
    }
}

