import Foundation
import Observation
import OSLog

/// What the live half of the app is doing, and the only thing allowed to say so.
///
/// This replaces three flags that could disagree with each other: a purpose
/// (`dictation` or `captions`), a polish stage, and the session's own phase.
/// Nothing stopped them contradicting, and the contradictions were reachable —
/// holding the Globe key while the model was still rewriting the previous
/// utterance started a capture on top of a delivery, and a capture that failed
/// to start left the purpose set to dictation forever.
///
/// So the states are named, the legal moves between them are written down in
/// one table, and everything else reads this rather than keeping its own idea.
/// A move that is not in the table does not happen: `move(to:)` returns false
/// and the caller does nothing, which turns a race into a refused button.
@MainActor
@Observable
final class Activity {
    enum State: Equatable {
        /// Nothing running.
        case idle
        /// Capturing, with the key or the button held down.
        case dictating
        /// Let go. The release pass is decoding the whole utterance.
        case transcribing
        /// The model is rewriting what was said.
        case polishing
        /// The words landed. Held for a beat so the change is visible.
        case delivered
        /// Live captions, which run until switched off.
        case captioning
        case failed(String)
    }

    private(set) var state: State = .idle

    @ObservationIgnored private var lapse: Task<Void, Never>?
    private let log = Logger(subsystem: "br.com.zesmoi.Shirusu", category: "activity")

    /// Moves, if the move is legal. Returns whether it happened.
    @discardableResult
    func move(to next: State) -> Bool {
        guard Self.allows(state, to: next) else {
            log.notice(
                """
                Refused \(String(describing: self.state), privacy: .public) -> \
                \(String(describing: next), privacy: .public)
                """)
            return false
        }
        state = next
        watch(next)
        return true
    }

    /// How long a state may last before it is assumed to be stuck.
    ///
    /// Only the transient ones have a limit. `idle` and `captioning` are places
    /// to stay; the rest are steps that something else is supposed to move on
    /// from, and if that something stops reporting, the alternative to a timer
    /// here is a dead Globe key until the app is relaunched. That is not
    /// hypothetical: it is the bug this was added for.
    ///
    /// The numbers are ceilings, not estimates. A release pass over five
    /// minutes of speech takes a couple of seconds.
    private static func limit(of state: State) -> Duration? {
        switch state {
        case .transcribing: return .seconds(60)
        case .polishing: return .seconds(30)
        case .delivered: return .seconds(10)
        case .idle, .dictating, .captioning, .failed: return nil
        }
    }

    private func watch(_ state: State) {
        lapse?.cancel()
        lapse = nil
        guard let limit = Self.limit(of: state) else { return }
        lapse = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self, self.state == state else { return }
            self.log.error(
                """
                Stuck in \(String(describing: state), privacy: .public); \
                releasing so the key works again
                """)
            self.state = .idle
        }
    }

    /// The whole transition table, which is also the specification.
    static func allows(_ current: State, to next: State) -> Bool {
        if current == next { return true }

        switch (current, next) {
        // Anything can fail, and a failure is always cleared by going idle.
        case (_, .failed), (.failed, .idle):
            return true

        // Dictation, start to finish.
        case (.idle, .dictating),
            (.dictating, .transcribing),
            (.transcribing, .polishing),
            (.transcribing, .delivered),
            (.polishing, .delivered),
            (.delivered, .idle):
            return true

        // A run that produced nothing, was thrown away, or gave up. A press
        // too short to transcribe ends here, and before this existed it ended
        // nowhere: the machine sat in `transcribing` and every later press was
        // refused until the app was relaunched.
        case (.dictating, .idle), (.transcribing, .idle), (.polishing, .idle):
            return true

        // Dictating again before the last result has faded. The bar is still
        // showing the previous utterance, but the person has clearly moved on.
        case (.delivered, .dictating):
            return true

        // Captions are a switch, not a sequence. Nothing leads into them and
        // nothing leads out but stopping, which is what keeps them from
        // overlapping a dictation: there is one live session and it does one
        // job at a time.
        case (.idle, .captioning), (.captioning, .idle):
            return true

        default:
            return false
        }
    }

    // MARK: - What the rest of the app asks

    var isCaptioning: Bool { state == .captioning }

    /// Capturing right now, either way.
    var isCapturing: Bool { state == .dictating || state == .captioning }

    /// Between letting go and the words landing.
    var isWorking: Bool { state == .transcribing || state == .polishing }

    var failure: String? {
        if case .failed(let message) = state { return message }
        return nil
    }
}
