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

    /// What the live session is doing, if anything.
    enum Purpose: Equatable { case dictation, captions }
    private(set) var live: Purpose?

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

        var id: String { rawValue }

        var label: String {
            switch self {
            case .transcribe:
                return String(localized: "Transcribe", comment: "Mode: turn an audio file into text")
            case .captions:
                return String(localized: "Live Captions", comment: "Mode: caption what the Mac hears")
            case .dictation:
                return String(localized: "Dictation", comment: "Mode: speak and have the text typed")
            }
        }

        var symbol: String {
            switch self {
            case .transcribe: return "waveform"
            case .captions: return "captions.bubble"
            case .dictation: return "mic"
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

    var mode: Mode = AppModel.storedMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: AppModel.modeKey)
            if isRambler { rambler.prepare() }
            // Nothing is stopped here on purpose. The sidebar chooses what you
            // are looking at, not what the app is doing: captions left on stay
            // on while you read a transcript, and the sidebar row says so.
        }
    }

    var delivery: Delivery = AppModel.storedDelivery {
        didSet { UserDefaults.standard.set(delivery.rawValue, forKey: AppModel.deliveryKey) }
    }

    /// The last thing dictation delivered, so the screen can show it landed.
    private(set) var lastDictation: String?

    /// Which microphone to open, remembered by UID.
    var inputDeviceUID: String? = UserDefaults.standard.string(forKey: AppModel.inputKey) {
        didSet { UserDefaults.standard.set(inputDeviceUID, forKey: AppModel.inputKey) }
    }

    /// The inputs this Mac has right now, kept current as they come and go.
    let inputs = AudioInputs()

    /// Cleans dictation up on release, when it is switched on.
    let rambler = Rambler()

    /// The rewrite profiles, built-in and the user's own.
    let profiles = RewriteProfiles()

    /// Whether to tidy dictation before it is delivered.
    var isRambler: Bool = UserDefaults.standard.bool(forKey: AppModel.ramblerKey) {
        didSet {
            UserDefaults.standard.set(isRambler, forKey: AppModel.ramblerKey)
            if isRambler { rambler.prepare() }
        }
    }

    /// What the model is doing to what was just said.
    enum Polish: Equatable {
        case idle
        case working
        /// It landed. Held for a moment so the change is visible before the bar
        /// goes: the whole point of the feature happens in that one beat.
        case settling
    }

    private(set) var polish: Polish = .idle

    private static let modeKey = "mode"
    private static let inputKey = "inputDevice"
    private static let sourceKey = "captureSource"
    private static let ramblerKey = "rambler"
    private static let deliveryKey = "delivery"

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
    private(set) var captureProblem: String?

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
            let live = TranscriptionSession(models: models, engine: engine)
            // Only an utterance run finishes, and only dictation makes one:
            // captions run continuously and never take a release pass.
            live.onFinish = { [weak self] text in
                Task { await self?.deliver(text) }
            }
            self.liveSession = live
            self.fileSession = TranscriptionSession(models: models, engine: engine)
            stage = .ready
            // Warm the release pass in the background: the window is already
            // usable, and the first press should not pay for it.
            Task { await live.prepare() }
            if isRambler { rambler.prepare() }
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
            guard let self, self.live == .dictation else { return }
            self.liveSession?.stop()
            // A ceiling, not the plan: delivery takes the bar down as soon as
            // the words have landed. This is only here so a pass that never
            // finishes does not leave the bar up for good.
            self.captions.hide(after: self.isRambler ? 12 : 2)
        }
    }

    /// Hands the finished text wherever this mode says it goes.
    private func deliver(_ text: String) async {
        var text = text
        if isRambler {
            // Surfaced, because it is a second or two of someone waiting with
            // their hands over the keyboard. An unexplained pause there reads
            // as the dictation having failed.
            polish = .working
            let polished = await rambler.polish(text, profile: profiles.selected)
            if polished != text {
                text = polished
                // Put the result where the raw text was. Watching the filler
                // words go is the only way to see what this feature did, and it
                // costs nothing: the bar is still up.
                session?.transcript.apply(confirmed: text, volatile: "")
            }
            polish = .settling
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, self.polish == .settling else { return }
                self.polish = .idle
            }
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
                captureProblem = error.localizedDescription
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
    var isCaptioning: Bool {
        live == .captions && (liveSession?.phase.isBusy ?? false)
    }

    /// Live captions run until they are switched off. No key to hold: the point
    /// is captioning a call or a video, which is not something you can hold a
    /// key through.
    func toggleLiveCaptions() {
        if isCaptioning {
            session?.stop()
            captions.hide(after: 2)
        } else {
            showCaptions()
            beginCapture(.captions)
        }
    }

    func showCaptions() {
        captions.show(CaptionView().environment(self))
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
        captureProblem = nil
        live = purpose

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
                    self.captureProblem = MicrophoneError.accessDenied.localizedDescription
                    self.live = nil
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
