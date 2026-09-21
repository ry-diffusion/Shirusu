import Dispatch
import Foundation

/// How long a loaded model stays in memory with nothing asking for it.
///
/// Weights are the largest thing this app holds, and an app left open all day
/// spends most of that day neither speaking nor listening. The three numbers
/// differ because the cost of being wrong differs: reaching for a voice is a
/// deliberate press that already waits on a progress bar, while dictation
/// answers a hotkey and has nowhere to put the delay.
nonisolated enum ModelIdle {
    /// Chatterbox holds around 1.7 GB and VoxCPM2 around 3.2, both promoted to
    /// float32 on Apple Silicon. They are reached for by pressing Listen and
    /// waiting, so paying the load again is a cost already in the shape of the
    /// feature — and holding three gigabytes for a voice nobody has asked for
    /// in ten minutes is the thing most worth not doing.
    static let voice: Duration = .seconds(120)

    /// Supertonic is four compact CoreML stages rather than gigabytes, and it
    /// is the default voice, so it is the one most likely to be asked for
    /// twice in a row. Cheap to hold and expensive to be wrong about, which
    /// argues for longer than the heavy pair.
    static let supertonic: Duration = .seconds(600)

    /// Dictation answers the Globe key, and a reload costs the CoreML load
    /// plus the Neural Engine specialisation that launch goes out of its way
    /// to pay in advance. Long enough that no working session ever meets it,
    /// short enough that an app left open overnight is not still holding the
    /// weights at breakfast.
    static let transcription: Duration = .seconds(1800)
}

/// Who is using a model right now, and when the last of them stopped.
///
/// The count matters as much as the clock. A deadline falling due in the
/// middle of a two-minute synthesis must not pull the weights out from under
/// it, and a run that outlives its own deadline should start the clock when it
/// ends rather than expire the instant it does.
nonisolated struct ModelUse {
    private var active = 0
    private var idleSince: ContinuousClock.Instant?

    /// Loaded and in use. Nothing expires while this is outstanding.
    mutating func begin() {
        active += 1
        idleSince = nil
    }

    /// One fewer user. The clock starts again only when the last one leaves.
    mutating func end() {
        active = max(0, active - 1)
        if active == 0 { idleSince = .now }
    }

    /// Loaded, with nobody using it yet — a warm-up, or a preload from opening
    /// a tab. It has to start the clock, or a model warmed and never used
    /// would sit there for the life of the process.
    mutating func idle() {
        if active == 0 { idleSince = .now }
    }

    /// Unloaded. There is nothing left to expire.
    mutating func forget() {
        active = 0
        idleSince = nil
    }

    /// Someone is mid-run. Whatever the deadline says, and whatever the
    /// system is asking for, this is the one model that is definitely needed.
    var isActive: Bool { active > 0 }

    func hasExpired(after interval: Duration) -> Bool {
        guard active == 0, let idleSince else { return false }
        return idleSince.duration(to: .now) >= interval
    }
}

/// The system asking for memory back.
///
/// A deadline answers the ordinary case — nobody has used this in a while —
/// and says nothing about the case that actually hurts, where something else
/// on the Mac needs the memory *now* and the deadline is twenty minutes out.
/// macOS is willing to say so, so there is no reason to make it wait.
final class MemoryPressureWatch {
    private let source: DispatchSourceMemoryPressure

    /// - Parameter onPressure: run on the main queue whenever the system
    ///   reports warning or critical pressure. `.normal` is not subscribed to:
    ///   there is nothing to do on the news that things are fine.
    init(onPressure: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler(handler: onPressure)
        source.resume()
    }

    deinit { source.cancel() }
}
