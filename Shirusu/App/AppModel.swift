import AppKit
import FluidAudio
import Foundation
import Observation
import OSLog
import SwiftUI

/// Root state. The app has exactly three states worth distinguishing: getting the
/// models ready, working, and broken.
@MainActor
@Observable
final class AppModel {
    enum Stage: Equatable {
        case preparing
        case ready
        case failed(String)
    }

    private(set) var stage: Stage = .preparing
    private(set) var setupStep: ModelSetup.Step = .checking
    private(set) var setupFraction: Double = 0
    /// Whether this run is the one that has to fetch the models.
    private(set) var isFirstInstall = false
    /// Two transcripts, one engine.
    ///
    /// They were one session, and that is why the Globe key only worked on the
    /// Dictation screen: a press anywhere else would have reset the transcript
    /// of the file you were reading. Separating them costs a `Transcript` and a
    /// buffer, not a second copy of the model, so the key now works wherever
    /// you happen to be looking.
    private(set) var liveSession: TranscriptionSession?
    private(set) var fileSession: TranscriptionSession?

    /// The one the caption bar and the Globe key drive.
    var session: TranscriptionSession? { liveSession }

    /// Which of the two live jobs a capture is for.
    enum Purpose: Equatable { case dictation, captions }

    /// What the live half of the app is doing. One answer, and a checked one.
    let activity = Activity()

    /// The delivery in flight, and which dictation it belongs to.
    ///
    /// Pressing the Globe key abandons both. Cancelling alone is not enough:
    /// `respond` may already be past the point of noticing, and a rewrite that
    /// lands after the interruption would be typed into the middle of the
    /// sentence being dictated now. The number is what makes that impossible.
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?
    @ObservationIgnored private var runNumber = 0

    /// The three jobs one engine can do, and the only thing the Globe key needs
    /// to know.
    ///
    /// They are modes rather than three buttons on one screen because they want
    /// opposite things from the same machinery. Transcribing a file is a
    /// document task: it has a beginning, an end, and a result worth keeping.
    /// Captions and dictation are both held-key tasks that run while the window
    /// is closed, and they differ in where the words go — on screen for other
    /// people to read, or into the app you were already typing in.
    enum Mode: String, CaseIterable, Identifiable {
        case transcribe
        case captions
        case dictation
        case speech

        var id: String { rawValue }

        var label: String {
            switch self {
            case .transcribe:
                return String(localized: "Transcribe", comment: "Mode: turn an audio file into text")
            case .captions:
                return String(localized: "Live Captions", comment: "Mode: caption what the Mac hears")
            case .dictation:
                return String(localized: "Dictation", comment: "Mode: speak and have the text typed")
            case .speech:
                return String(localized: "Text to Speech", comment: "Mode: turn written text into spoken audio")
            }
        }

        var symbol: String {
            switch self {
            case .transcribe: return "waveform"
            case .captions: return "captions.bubble"
            case .dictation: return "mic"
            case .speech: return "speaker.wave.3"
            }
        }

        /// One line under the title. Says what the mode does, not what it is.
        var summary: String {
            switch self {
            case .transcribe:
                return String(
                    localized: "Drop in a recording and read it back as text.",
                    comment: "Subtitle for the Transcribe mode")
            case .captions:
                return String(
                    localized: "Hold the Globe key and a caption bar follows what is being said.",
                    comment: "Subtitle for the Live Captions mode")
            case .dictation:
                return String(
                    localized: "Hold the Globe key, speak, and the words are typed where your cursor is.",
                    comment: "Subtitle for the Dictation mode")
            case .speech:
                return String(
                    localized: "Write something and hear it with a local voice.",
                    comment: "Subtitle for the Text to Speech mode")
            }
        }

        /// Whether holding the Globe key does anything in this mode.
        var isLive: Bool { self != .transcribe }
    }

    /// Where dictated words go once the key is released.
    enum Delivery: String, CaseIterable, Identifiable {
        /// Typed into whatever had focus.
        case insert
        /// Left on the clipboard to be pasted by hand.
        case clipboard

        var id: String { rawValue }

        var label: String {
            switch self {
            case .insert:
                return String(localized: "Type it where my cursor is", comment: "Dictation delivery")
            case .clipboard:
                return String(localized: "Copy it to the clipboard", comment: "Dictation delivery")
            }
        }
    }

    /// How often continuous captions ask the recogniser for a fresh preview.
    /// These are a lower bound, not a promise: a slower model pass naturally
    /// takes precedence so runs never overlap.
    enum CaptionUpdateRate: String, CaseIterable, Identifiable {
        case instant
        case normal
        case slow

        var id: String { rawValue }

        var label: String {
            switch self {
            case .instant:
                return String(localized: "Instant", comment: "Caption update rate")
            case .normal:
                return String(localized: "Normal", comment: "Caption update rate")
            case .slow:
                return String(localized: "Slow", comment: "Caption update rate")
            }
        }

        var interval: Double {
            switch self {
            case .instant: return 0.12
            case .normal: return 0.6
            // Still notably cheaper than Normal, but short enough that a fast
            // dialogue does not look as though captions are skipping beats.
            case .slow: return 0.9
            }
        }
    }

    var mode: Mode = AppModel.storedMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: AppModel.modeKey)
            // Nothing is stopped here on purpose. The sidebar chooses what you
            // are looking at, not what the app is doing: captions left on stay
            // on while you read a transcript, and the sidebar row says so.
        }
    }

    var delivery: Delivery = AppModel.storedDelivery {
        didSet { UserDefaults.standard.set(delivery.rawValue, forKey: AppModel.deliveryKey) }
    }

    /// Saved independently from the input source; a person may prefer slow
    /// captions for a film but still want system audio as the source.
    var captionUpdateRate: CaptionUpdateRate = AppModel.storedCaptionUpdateRate {
        didSet {
            UserDefaults.standard.set(captionUpdateRate.rawValue, forKey: AppModel.captionUpdateRateKey)
            liveSession?.setContinuousUpdateInterval(captionUpdateRate.interval)
        }
    }

    /// The last thing dictation delivered, so the screen can show it landed.
    private(set) var lastDictation: String?

    /// Which microphone to open, remembered by UID.
    var inputDeviceUID: String? = UserDefaults.standard.string(forKey: AppModel.inputKey) {
        didSet { UserDefaults.standard.set(inputDeviceUID, forKey: AppModel.inputKey) }
    }

    /// The inputs this Mac has right now, kept current as they come and go.
    let inputs = AudioInputs()

    /// Chooses the on-device or cloud rewrite engine and owns its secret.
    let modelConfig: ModelConfig

    /// Cleans dictation up on release, when it is switched on.
    let rambler: Rambler

    /// The rewrite profiles, built-in and the user's own.
    let profiles = RewriteProfiles()

    /// Separate from dictation deliberately: it owns model download, synthesis
    /// and output playback, while dictation only needs a microphone and text.
    let speech = SpeechSession()

    /// The saved reference voices, and which one a copy should use.
    let voices = VoiceProfiles()

    /// The same engine the two sessions transcribe with, kept here so a voice
    /// recorded for cloning can be checked against what it was meant to say.
    /// Absent until the model has landed.
    private(set) var transcriber: BatchTranscriber?

    /// Whether to tidy dictation before it is delivered.
    var isRambler: Bool = UserDefaults.standard.bool(forKey: AppModel.ramblerKey) {
        didSet {
            UserDefaults.standard.set(isRambler, forKey: AppModel.ramblerKey)
            if isRambler { rambler.prepare(for: profiles.selected) }
        }
    }

    private static let modeKey = "mode"
    private static let inputKey = "inputDevice"
    private static let sourceKey = "captureSource"
    private static let captionUpdateRateKey = "captionUpdateRate"
    private static let ramblerKey = "rambler"
    private static let deliveryKey = "delivery"

    init() {
        let settings = ModelConfig()
        modelConfig = settings
        rambler = Rambler(settings: settings)
    }

    /// Opens where it was left. First run starts on Transcribe: it is the one
    /// mode that works before any permission has been granted, so the app has
    /// something to show rather than a wall of requests.
    private static var storedMode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .transcribe
    }

    /// Captions default to what the Mac is playing, which is what they are for.
    private static var storedSource: CaptureSource {
        CaptureSource(rawValue: UserDefaults.standard.string(forKey: sourceKey) ?? "") ?? .systemAudio
    }

    private static var storedDelivery: Delivery {
        Delivery(rawValue: UserDefaults.standard.string(forKey: deliveryKey) ?? "") ?? .insert
    }

    private static var storedCaptionUpdateRate: CaptionUpdateRate {
        CaptionUpdateRate(rawValue: UserDefaults.standard.string(forKey: captionUpdateRateKey) ?? "")
            ?? .normal
    }

    /// Where the audio comes from. The microphone hears the room; system audio
    /// hears what the Mac is playing, which is how you transcribe a call or a
    /// voice message without holding a phone to the laptop.
    enum CaptureSource: String, CaseIterable, Identifiable {
        case microphone
        case systemAudio

        var id: String { rawValue }

        var label: String {
            switch self {
            case .microphone:
                return String(localized: "Microphone", comment: "Capture source")
            case .systemAudio:
                return String(localized: "System audio", comment: "Capture source")
            }
        }

        var symbol: String {
            switch self {
            case .microphone: return "mic.fill"
            case .systemAudio: return "speaker.wave.2.fill"
            }
        }
    }

    var captureSource: CaptureSource = AppModel.storedSource {
        didSet { UserDefaults.standard.set(captureSource.rawValue, forKey: AppModel.sourceKey) }
    }
    /// Surfaced so the UI can explain a refusal instead of going quiet.
    private(set) var captureProblem: CaptureProblem?

    let hotkey = GlobeHotkeyMonitor()
    let captions = CaptionPanel()
    private let log = Logger(subsystem: "br.com.zesmoi.Shirusu", category: "app")

    func bootstrap() async {
        guard stage != .ready else { return }

        stage = .preparing
        isFirstInstall = !ShirusuModel.isInstalled
        setupFraction = 0
        setupStep = .checking

        do {
            // AppModel lives as long as the process, so a strong capture here is
            // the honest one; a weak dance would only obscure that.
            let models = try await ModelSetup.prepare { step, fraction in
                Task { @MainActor in
                    self.setupStep = step
                    // Progress that only ever moves forward. A bar that retreats
                    // reads as a bug even when the underlying number is honest.
                    self.setupFraction = max(self.setupFraction, fraction)
                }
            }
            // One engine behind both, so the weights load once.
            let engine = BatchTranscriber()
            transcriber = engine
            let live = TranscriptionSession(models: models, engine: engine)
            live.setContinuousUpdateInterval(captionUpdateRate.interval)
            // Only an utterance run finishes, and only dictation makes one:
            // captions run continuously and never take a release pass.
            live.onFinish = { [weak self] text in
                guard let self else { return }
                self.deliveryTask = Task { await self.deliver(text) }
            }
            // A state released for taking too long is a reason too.
            activity.onStuck = { [weak self] _ in
                guard let self else { return }
                self.rambler.note(.timedOut, profile: self.profiles.selected)
                // Nothing else is going to take it down now.
                self.captions.hide(after: 0.6)
            }
            self.liveSession = live
            self.fileSession = TranscriptionSession(models: models, engine: engine)
            stage = .ready
            // Warm the release pass in the background: the window is already
            // usable, and the first press should not pay for it.
            // Warmed after the first-run screen has finished animating out,
            // not during it. Loading the CoreML graph and pushing a throwaway
            // second of audio through the Neural Engine is the heaviest thing
            // this app does, and doing it while the setup view is still
            // cross-fading drops frames in the middle of the animation.
            //
            // It has to happen at launch either way: unwarmed, the whole cost
            // lands on the first press of the Globe key, which is the one press
            // where a delay reads as the feature being slow.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                await live.prepare()
                guard let self else { return }
                self.rambler.prepare(for: self.profiles.selected)
                // The window the caption lives in, built but not shown.
                self.captions.prepare(self.captionView())
            }
            bindHotkey()
            // Arm it without asking: if Accessibility was already granted this
            // just works, and if it was not, the toolbar shows why.
            let armed = hotkey.enable()
            log.notice(
                """
                Globe key: \(armed ? "armed" : "not armed", privacy: .public),                 availability \(String(describing: self.hotkey.availability), privacy: .public),                 accessibility \(self.hotkey.hasAccessibilityPermission, privacy: .public),                 key free \(self.hotkey.isGlobeKeyFree, privacy: .public)
                """)
        } catch {
            log.error("Model setup failed: \(error.localizedDescription, privacy: .public)")
            stage = .failed(error.localizedDescription)
        }
    }

    func retry() {
        stage = .preparing
        Task { await bootstrap() }
    }
}

extension AppModel {
    /// Hold to talk, release to transcribe.
    ///
    /// The key is deliberately dead in Transcribe mode. There is one session
    /// and one transcript behind all three modes, so a press there would wipe
    /// the file you just transcribed to make room for three seconds of speech.
    /// Refusing to start is the cheaper surprise, and the screen says so.
    func bindHotkey() {
        hotkey.onPress = { [weak self] in
            guard let self else { return }
            // Always dictation, from wherever you are. Live captions have their
            // own switch, which is what they asked for: you cannot hold a key
            // through a film.
            self.showCaptions()
            self.beginCapture(.dictation)
        }
        hotkey.onRelease = { [weak self] in
            guard let self, self.activity.state == .dictating else { return }
            // Only if there is actually a run to finish. A press that never
            // started one has nothing to report back, so it goes straight home
            // rather than waiting to be told about a run that does not exist.
            guard let session = self.liveSession, session.phase.isBusy else {
                self.activity.move(to: .idle)
                self.captions.hide(after: 0.6)
                return
            }
            self.activity.move(to: .transcribing)
            session.stop()
            // No timer when a rewrite is coming. A profile that writes a page
            // from one sentence takes half a minute, measured, and a bar that
            // vanishes on a guess while the work is still running is the app
            // looking finished when it is not. Delivery takes it down when the
            // words actually land, and the stuck watchdog is the backstop.
            if !self.isRambler { self.captions.hide(after: 2) }
        }
    }

    /// Hands the finished text wherever this mode says it goes.
    private func deliver(_ text: String) async {
        guard !text.isEmpty else {
            // Nothing was heard. Nothing to type, nothing to show, and the
            // machine has to be told or the next press is refused.
            activity.move(to: .idle)
            captions.hide(after: 0.6)
            return
        }

        let mine = runNumber
        var text = text
        if isRambler {
            guard activity.move(to: .polishing) else {
                // Already interrupted, before the rewrite even started.
                rambler.note(.interrupted, profile: profiles.selected)
                return
            }
            // Surfaced, because it is a second or two of someone waiting with
            // their hands over the keyboard. An unexplained pause there reads
            // as the dictation having failed.
            let polished = await rambler.polish(text, profile: profiles.selected)

            guard mine == runNumber, !Task.isCancelled else {
                // A new dictation started while this was being rewritten. It
                // owns the machine and the caption bar now, so this one goes
                // quietly rather than typing itself into the middle of it.
                rambler.note(.interrupted, profile: profiles.selected)
                return
            }
            if polished != text {
                text = polished
                // Put the result where the raw text was. Watching the filler
                // words go is the only way to see what this feature did, and it
                // costs nothing: the bar is still up.
                liveSession?.transcript.apply(confirmed: text, volatile: "")
            }
        }
        activity.move(to: .delivered)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, self.activity.state == .delivered else { return }
            self.activity.move(to: .idle)
        }

        lastDictation = text
        defer { captions.hide(after: 1.2) }

        switch delivery {
        case .insert:
            do {
                try TextInsertion.insert(text)
            } catch {
                // Never drop the words on the floor: if they could not be
                // typed, they are still on the clipboard and the screen says
                // what went wrong.
                captureProblem = .typing(
                    error.localizedDescription,
                    remedy: error is TextInsertion.Failure ? .accessibility : nil)
                copyToClipboard(text)
            }
        case .clipboard:
            copyToClipboard(text)
        }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Whether live captions are running.
    ///
    /// Derived from the session rather than stored beside it. A stored flag and
    /// a session that failed to start are two answers to one question, and the
    /// switch would be left on over a caption bar showing nothing.
    var isCaptioning: Bool { activity.isCaptioning }

    /// Live captions run until they are switched off. No key to hold: the point
    /// is captioning a call or a video, which is not something you can hold a
    /// key through.
    func toggleLiveCaptions() {
        setLiveCaptions(!isCaptioning)
    }

    /// Keeps the SwiftUI switch's desired value and the capture lifecycle in
    /// lockstep. The panel may be hidden while captions are running, so it is
    /// deliberately not the source of truth here.
    func setLiveCaptions(_ enabled: Bool) {
        guard enabled != isCaptioning else { return }

        if enabled {
            showCaptions()
            beginCapture(.captions)
        } else {
            // A continuous run has no release pass to preserve. Cancelling it
            // clears the input immediately, then clearing the transcript keeps
            // the hidden panel from being brought back by stale words when the
            // activity returns to idle.
            session?.discard()
            session?.clear()
            activity.move(to: .idle)
            captions.hide()
        }
    }

    func showCaptions() {
        captions.show(captionView())
    }

    private func captionView() -> some View {
        CaptionView(onVisibilityChange: { [weak self] visible in
            self?.captions.setContentVisible(visible)
        })
        .environment(self)
    }

    func toggleCaptions() {
        captions.isVisible ? captions.hide() : showCaptions()
    }

    @discardableResult
    func enableHotkey() -> Bool {
        hotkey.enable()
    }

    func beginCapture(_ purpose: Purpose) {
        guard let session = liveSession, !session.phase.isBusy else { return }
        // The machine decides whether this is allowed at all, which is what
        // stops a press landing on top of a delivery that has not finished.
        guard activity.move(to: purpose == .dictation ? .dictating : .captioning) else { return }
        // Whatever the last press left running is no longer wanted.
        deliveryTask?.cancel()
        deliveryTask = nil
        runNumber &+= 1
        captureProblem = nil

        // Dictation is always the microphone: the point is your own voice, and
        // offering a choice there would only be a way to get it wrong. Captions
        // read either the room or what the Mac is playing, which is how you
        // caption a call.
        let source: CaptureSource = purpose == .dictation ? .microphone : captureSource
        let intent: TranscriptionSession.Intent =
            purpose == .dictation ? .utterance : .continuous

        Task { [weak self] in
            guard let self else { return }
            switch source {
            case .microphone:
                guard await MicrophoneFeed.requestAccess() else {
                    let message = MicrophoneError.accessDenied.localizedDescription
                    self.captureProblem = .listening(message, remedy: .microphone)
                    self.activity.move(to: .failed(message))
                    self.activity.move(to: .idle)
                    return
                }
                session.start(
                    MicrophoneFeed(device: self.inputs.resolve(self.inputDeviceUID)),
                    intent: intent
                )
            case .systemAudio:
                // The tap asks the system for permission on first start, and
                // reports a refusal as a thrown error rather than silence.
                session.start(SystemAudioFeed(), intent: intent)
            }
        }
    }

    func endCapture() {
        liveSession?.stop()
    }

    func clearCaptureProblem() {
        captureProblem = nil
    }
}
