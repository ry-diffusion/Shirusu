import Testing

@testable import Shirusu

/// The transition table, checked both ways.
///
/// Worth its own tests because the table is the specification: every state this
/// app can be in is in it, and the moves that are not in it are the bugs it
/// exists to stop. All of it is pure, so none of this needs audio, a model, or
/// a running app.
@MainActor
struct ActivityTests {
    @Test("A dictation runs start to finish")
    func dictationPath() {
        let activity = Activity()
        #expect(activity.state == .idle)
        #expect(activity.move(to: .dictating))
        #expect(activity.move(to: .transcribing))
        #expect(activity.move(to: .polishing))
        #expect(activity.move(to: .delivered))
        #expect(activity.move(to: .idle))
    }

    @Test("Dictation without Rambler skips polishing")
    func dictationWithoutRambler() {
        let activity = Activity()
        #expect(activity.move(to: .dictating))
        #expect(activity.move(to: .transcribing))
        #expect(activity.move(to: .delivered))
    }

    @Test("The Globe key interrupts whatever is in flight")
    func pressInterruptsWork() {
        // It used to be refused, on the grounds that a rewrite landing in the
        // middle of the next sentence is worse than a dead key. It is not:
        // when Apple Intelligence stopped answering, the key sat dead for half
        // a minute. The press wins, and AppModel abandons what it interrupted.
        for busy in [Activity.State.transcribing, .polishing] {
            let activity = Activity()
            activity.move(to: .dictating)
            activity.move(to: .transcribing)
            if busy == .polishing { activity.move(to: .polishing) }
            #expect(activity.state == busy)
            #expect(activity.move(to: .dictating))
        }
    }

    @Test("A failure does not need clearing before the key works again")
    func pressAfterFailure() {
        let activity = Activity()
        activity.move(to: .dictating)
        activity.move(to: .failed("no microphone"))
        #expect(activity.move(to: .dictating))
    }

    @Test("Dictating again while the last result is still on screen is fine")
    func pressDuringTheSettle() {
        let activity = Activity()
        activity.move(to: .dictating)
        activity.move(to: .transcribing)
        activity.move(to: .delivered)
        #expect(activity.move(to: .dictating))
    }

    @Test("Captions are the one thing the key does not interrupt")
    func captionsAreExclusive() {
        // Stopping a caption run someone switched on, without being asked and
        // without putting it back, is a worse surprise than a press that does
        // nothing. Captions have their own switch.
        let activity = Activity()
        #expect(activity.move(to: .captioning))
        #expect(!activity.move(to: .dictating))
        #expect(!activity.move(to: .transcribing))
        #expect(activity.state == .captioning)

        #expect(activity.move(to: .idle))
        #expect(activity.move(to: .dictating))
        #expect(!activity.move(to: .captioning))
    }

    @Test("A run that produced nothing goes back to idle from wherever it got to")
    func nothingCameOfIt() {
        // The bug this exists for: a press too short to transcribe used to
        // leave the machine in `transcribing`, and every later press was
        // refused until the app was relaunched.
        for stall in [Activity.State.dictating, .transcribing, .polishing] {
            let activity = Activity()
            activity.move(to: .dictating)
            if stall != .dictating { activity.move(to: .transcribing) }
            if stall == .polishing { activity.move(to: .polishing) }
            #expect(activity.state == stall)
            #expect(activity.move(to: .idle))
            #expect(activity.move(to: .dictating), "the key has to work again")
        }
    }

    @Test("Anything can fail, and a failure is cleared by going idle")
    func failureFromAnywhere() {
        for start in [Activity.State.dictating, .transcribing, .polishing, .captioning] {
            let activity = Activity()
            if start != .dictating && start != .captioning {
                activity.move(to: .dictating)
                if start == .polishing { activity.move(to: .transcribing) }
            }
            activity.move(to: start)
            #expect(activity.move(to: .failed("no microphone")))
            #expect(activity.failure == "no microphone")
            #expect(activity.move(to: .idle))
            #expect(activity.failure == nil)
        }
    }

    /// `.dictating` is deliberately not here: the Globe key is an escape hatch
    /// and wins from a failure too, which is what `pressAfterFailure` asserts.
    /// This test predates that and went on insisting on the opposite.
    @Test("A failure leads nowhere but idle, or back into dictating")
    func failureIsATerminus() {
        let activity = Activity()
        activity.move(to: .failed("broken"))
        #expect(!activity.move(to: .captioning))
        #expect(!activity.move(to: .delivered))
        #expect(activity.move(to: .idle))
    }

    @Test("Moving to where you already are is not a failure")
    func selfMoveIsAllowed() {
        let activity = Activity()
        #expect(activity.move(to: .idle))
        activity.move(to: .captioning)
        #expect(activity.move(to: .captioning))
    }

    @Test("Delivery cannot be skipped to from nothing")
    func noShortcuts() {
        let activity = Activity()
        #expect(!activity.move(to: .transcribing))
        #expect(!activity.move(to: .polishing))
        #expect(!activity.move(to: .delivered))
        #expect(activity.state == .idle)
    }

    @Test("The questions the rest of the app asks line up with the state")
    func derivedAnswers() {
        let activity = Activity()
        #expect(!activity.isCapturing && !activity.isWorking && !activity.isCaptioning)

        activity.move(to: .dictating)
        #expect(activity.isCapturing && !activity.isWorking)

        activity.move(to: .transcribing)
        #expect(!activity.isCapturing && activity.isWorking)

        activity.move(to: .polishing)
        #expect(activity.isWorking)

        activity.move(to: .delivered)
        #expect(!activity.isWorking)

        activity.move(to: .idle)
        activity.move(to: .captioning)
        #expect(activity.isCaptioning && activity.isCapturing && !activity.isWorking)
    }
}
