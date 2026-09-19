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

    @Test("A press cannot land on top of work already running")
    func noPressWhileWorking() {
        let activity = Activity()
        activity.move(to: .dictating)
        activity.move(to: .transcribing)
        // The Globe key while the release pass is still decoding.
        #expect(!activity.move(to: .dictating))
        #expect(activity.state == .transcribing)

        activity.move(to: .polishing)
        // And while the model is rewriting it.
        #expect(!activity.move(to: .dictating))
        #expect(activity.state == .polishing)
    }

    @Test("Dictating again while the last result is still on screen is fine")
    func pressDuringTheSettle() {
        let activity = Activity()
        activity.move(to: .dictating)
        activity.move(to: .transcribing)
        activity.move(to: .delivered)
        #expect(activity.move(to: .dictating))
    }

    @Test("Captions and dictation cannot overlap: one session, one job")
    func captionsAreExclusive() {
        let activity = Activity()
        #expect(activity.move(to: .captioning))
        #expect(!activity.move(to: .dictating))
        #expect(!activity.move(to: .transcribing))
        #expect(activity.state == .captioning)

        #expect(activity.move(to: .idle))
        #expect(activity.move(to: .dictating))
        #expect(!activity.move(to: .captioning))
    }

    @Test("A capture that never produced anything goes back to idle")
    func abandonedPress() {
        let activity = Activity()
        activity.move(to: .dictating)
        #expect(activity.move(to: .idle))
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

    @Test("A failure does not lead anywhere but idle")
    func failureIsATerminus() {
        let activity = Activity()
        activity.move(to: .failed("broken"))
        #expect(!activity.move(to: .dictating))
        #expect(!activity.move(to: .captioning))
        #expect(!activity.move(to: .delivered))
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
