import AVFoundation
import FluidAudio
import Foundation
import Observation
import OSLog

/// Drives one run of the pipeline: audio in, transcript out.
///
/// There is no streaming engine here, and that is the point. Parakeet decodes at
/// 160–220x realtime, so re-reading everything said so far costs 100 ms at five
/// seconds of audio and 240 ms at thirty. Cheap enough to simply do it again,
/// and again, while the person is still talking.
///
/// What that buys is a preview that is not a worse transcript from a second,
/// weaker engine — it *is* the transcript, punctuated and whole. The sliding
/// window it replaces showed seams ("a gente tá... aqui"); a cache-aware
/// streaming model would have cost another 590 MB resident and dropped
/// punctuation in Portuguese. This costs neither.
///
/// The preview reads only the last `previewWindow` seconds, so its cost stays
/// flat however long someone talks — re-reading the whole thing every pass went
/// from 100 ms at five seconds to 405 ms at forty-five. The complete transcript
/// is decoded once, on release, where paying for the whole utterance is both
/// affordable and the point.
@MainActor
@Observable
final class TranscriptionSession {
    /// What this run is for, which is the only thing the two live modes
    /// disagree about.
    enum Intent: Sendable {
        /// Something said once. Buffered whole and re-read on release, which is
        /// where the text you keep comes from.
        case utterance
        /// Something that keeps going. Only the preview window is kept, and
        /// switching it off does not trigger a pass over an hour of audio.
        case continuous
    }

    enum Phase: Equatable {
        case idle
        case starting
        case running
        case finishing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .starting, .running, .finishing: return true
            case .idle, .failed: return false
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = Transcript()
    /// Smoothed input level, 0...1.
    private(set) var level: Float = 0
    private(set) var sourceLabel: String?
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval?
    private(set) var startedAt: Date?

    /// Whether words are still arriving, for continuous runs only.
    ///
    /// Captions are read by someone who is not looking for them, so the bar has
    /// to earn its place on screen: present while there is something to read,
    /// gone the rest of the time. Dictation is the opposite and never uses
    /// this — you pressed a key, and the bar answering that is the point.
    private(set) var isSpeaking = false

    /// Called once with the finished text, after the release pass.
    ///
    /// Dictation needs a moment to act on, not a value to watch: the words have
    /// to be delivered exactly once, when they are final. Observing `transcript`
    /// would fire on every preview pass instead.
    var onFinish: ((String) -> Void)?

    private let models: AsrModels
    private let capture = UtteranceBuffer()
    /// Shared, not owned. The CoreML weights are most of a gigabyte, so the
    /// file screen and the live screens get their own transcript and their own
    /// buffer but decode through the same actor.
    private let engine: BatchTranscriber
    private var run: Task<Void, Never>?
    private var rolling: Task<Void, Never>?
    /// Set by `stop()`. The feed loop breaks on it and then finalises, which is
    /// the difference between releasing the key and throwing the audio away.
    private var isStopping = false
    private var intent: Intent = .utterance
    /// The previous pass's text, so an unchanged one is not re-applied.
    private var lastPreview = ""
    /// When a chunk last carried something louder than room tone.
    private var lastAudibleAt: ContinuousClock.Instant?
    private let log = Logger(subsystem: "br.com.zesmoi.Shirusu", category: "session")

    init(
        models: AsrModels,
        engine: BatchTranscriber = BatchTranscriber(),
        profile: ShirusuModel.Profile = .pushToTalk
    ) {
        self.models = models
        self.engine = engine
        // Vestigial: the sliding-window path it selected is gone, and the
        // tests still pass one. Accepted and ignored rather than churn them.
        _ = profile
    }

    var progress: Double? {
        guard let duration, duration > 0 else { return nil }
        return min(position / duration, 1)
    }

    /// Gets everything ready before the first press needs it.
    ///
    /// The microphone is deliberately not part of this. Opening an input device
    /// at launch is what triggers the permission prompt and lights the orange
    /// recording dot, and an app that does that on the way up looks like it is
    /// listening when it is not. The model is warmed; the microphone waits to
    /// be asked.
    func prepare() async {
        let started = ContinuousClock.now
        try? await engine.load(models)
        await engine.warmUp()
        log.info("Recogniser warm in \(started.duration(to: .now), privacy: .public)")
    }

    func start(_ feed: AudioFeed, intent: Intent = .utterance) {
        guard !phase.isBusy else { return }

        self.intent = intent
        isSpeaking = false
        lastPreview = ""
        lastAudibleAt = nil
        transcript.reset()
        phase = .starting
        sourceLabel = feed.label
        duration = feed.duration
        position = 0
        level = 0
        startedAt = .now
        isStopping = false

        run = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.load(self.models)
                // Captions keep a little more than the preview reads, so the
                // window is always full; an utterance keeps all of it.
                await self.capture.reset(
                    limit: intent == .continuous ? Self.previewWindow + 4 : nil
                )
                self.phase = .running
                self.startRolling()

                for try await chunk in feed.chunks() {
                    // `isStopping` is a release; cancellation is a discard.
                    if self.isStopping || Task.isCancelled { break }
                    self.absorb(chunk)
                    await self.capture.append(chunk.buffer)
                }

                self.rolling?.cancel()
                self.rolling = nil

                if Task.isCancelled || intent == .continuous {
                    _ = await self.capture.take()
                } else {
                    self.phase = .finishing
                    let final = try await self.engine.transcribe(self.capture.take())
                    if !final.isEmpty {
                        self.transcript.apply(confirmed: final, volatile: "")
                        self.onFinish?(final)
                    }
                }

                self.decay()
                self.phase = .idle
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                self.log.error("Session failed: \(error.localizedDescription, privacy: .public)")
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Re-reads the whole utterance on a schedule that throttles itself.
    ///
    /// Waiting as long as the last pass took keeps the duty cycle near half:
    /// a short utterance updates several times a second, a long one backs off
    /// on its own rather than saturating the Neural Engine.
    private func startRolling() {
        rolling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                // Nothing has been heard in a while, so there is nothing to
                // recognise: no encode, no decode, no Neural Engine. Captions
                // left on through a quiet afternoon spend that afternoon here,
                // and the bar and the meter hold still because there is
                // genuinely nothing to report.
                if self.intent == .continuous, !self.isAudible {
                    await self.fallSilent()
                    try? await Task.sleep(for: .seconds(Self.idleInterval))
                    continue
                }

                // Only the tail: the whole buffer is decoded once, at the end.
                let samples = await self.capture.recent(seconds: Self.previewWindow)

                var cost = Self.minimumInterval
                if samples.count >= BatchTranscriber.minimumSamples {
                    let started = ContinuousClock.now
                    if let text = try? await self.engine.transcribe(samples), !text.isEmpty,
                        text != self.lastPreview
                    {
                        // Identical text means the window is re-reading words
                        // already on screen, which is what silence looks like
                        // from here: the last thing said stays in the window
                        // for another twelve seconds after it was said.
                        self.lastPreview = text
                        // The preview is the transcript, so it arrives settled.
                        self.transcript.apply(confirmed: text, volatile: "")
                        self.noteSpeech()
                    }
                    let elapsed = ContinuousClock.now - started
                    cost =
                        Double(elapsed.components.seconds)
                        + Double(elapsed.components.attoseconds) / 1e18
                }

                let wait = max(Self.minimumInterval, cost)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func noteSpeech() {
        guard intent == .continuous else { return }
        isSpeaking = true
    }

    /// Whether anything louder than room tone has arrived recently enough to be
    /// worth decoding.
    private var isAudible: Bool {
        guard let lastAudibleAt else { return false }
        return ContinuousClock.now - lastAudibleAt < .seconds(Self.silenceTimeout)
    }

    /// Takes the caption down, and forgets what put it up.
    private func fallSilent() async {
        guard isSpeaking || !lastPreview.isEmpty else { return }
        isSpeaking = false
        transcript.reset()
        lastPreview = ""
        // The audio goes too. The preview window would otherwise still hold the
        // last sentence when someone speaks again a minute later, and the
        // caption coming back would open with words from before the pause.
        _ = await capture.take()
    }

    /// Below this a chunk is room tone, not speech. Peaks are normalised to
    /// 0...1 and conversation sits an order of magnitude above this.
    private static let silenceFloor: Float = 0.015

    /// Long enough to sit through a pause for breath, short enough that the bar
    /// is not still up when the conversation has moved on.
    private static let silenceTimeout: Double = 3.0

    /// How often to look while nothing is happening. Cheap enough to be
    /// frequent, and the gate below it costs nothing at all.
    private static let idleInterval: Double = 0.25

    private static let minimumInterval: Double = 0.12

    /// How much of the tail the preview re-reads. Twelve seconds costs about
    /// 130 ms a pass and is far more than the caption shows.
    private static let previewWindow = 12.0

    /// Releasing the key: stop listening, then transcribe what was said.
    func stop() {
        guard phase.isBusy else { return }
        isStopping = true
        isSpeaking = false
        decay()
    }

    /// Throwing it away: no transcript, no finishing pass.
    func discard() {
        isStopping = false
        isSpeaking = false
        rolling?.cancel()
        rolling = nil
        run?.cancel()
        run = nil
        decay()
        if phase.isBusy { phase = .idle }
    }

    func clear() {
        guard !phase.isBusy else { return }
        transcript.reset()
        sourceLabel = nil
        duration = nil
        position = 0
        startedAt = nil
        phase = .idle
    }

    /// Meter ballistics: jump to a louder peak immediately, fall back slowly.
    /// A meter that tracks the raw peak both ways reads as noise.
    private func absorb(_ chunk: AudioChunk) {
        let audible = chunk.peak > Self.silenceFloor
        if audible { lastAudibleAt = .now }
        // A continuous run counts speech, not how long the switch has been on.
        // An hour of quiet is not an hour of captions.
        if audible || intent != .continuous { position = chunk.position }
        level = chunk.peak > level ? chunk.peak : level * 0.82 + chunk.peak * 0.18
    }

    private func decay() {
        level = 0
    }
}
