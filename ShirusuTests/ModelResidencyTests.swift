import Testing

@testable import Shirusu

/// What decides whether a loaded model is still wanted.
///
/// Worth its own tests because getting it wrong is expensive in both
/// directions: too eager and a synthesis loses its weights mid-run, too shy
/// and the app holds three gigabytes it will never use again. All of it is a
/// counter and a clock, so none of this needs audio, a model, or a running
/// app.
struct ModelResidencyTests {
    @Test("Nothing expires before it has been loaded")
    func freshNeverExpires() {
        let use = ModelUse()
        #expect(!use.hasExpired(after: .zero))
    }

    @Test("Loaded and unused starts the clock")
    func idleStartsTheClock() {
        var use = ModelUse()
        use.idle()
        // A warm-up that nobody follows up on is exactly the case this exists
        // for: the weights are resident and no one has asked for them.
        #expect(use.hasExpired(after: .zero))
    }

    @Test("A run in flight holds the weights however long it takes")
    func activeRunNeverExpires() {
        var use = ModelUse()
        use.idle()
        use.begin()
        #expect(!use.hasExpired(after: .zero))
    }

    @Test("The clock restarts when the last user leaves, not the first")
    func lastUserOutStartsTheClock() {
        var use = ModelUse()
        use.begin()
        use.begin()
        use.end()
        // The file screen and the live screen decode through one engine, so
        // one of them finishing is not the model going idle.
        #expect(!use.hasExpired(after: .zero))
        use.end()
        #expect(use.hasExpired(after: .zero))
    }

    @Test("A deadline that has not come round yet holds")
    func unexpiredDeadlineHolds() {
        var use = ModelUse()
        use.begin()
        use.end()
        #expect(!use.hasExpired(after: .seconds(600)))
    }

    @Test("An unbalanced end does not leave the count below zero")
    func endWithoutBeginIsHarmless() {
        var use = ModelUse()
        use.end()
        use.begin()
        // Were `end` allowed to go negative, this `begin` would land on -1 +
        // 1 == 0 and the run would look idle while it was still decoding.
        #expect(!use.hasExpired(after: .zero))
    }

    @Test("Unloading leaves nothing to expire")
    func forgetStopsTheClock() {
        var use = ModelUse()
        use.idle()
        use.forget()
        // Otherwise the sweeper would keep finding an expired deadline for a
        // model that is already gone, and unload it again on every wake.
        #expect(!use.hasExpired(after: .zero))
    }

    @Test("A run in progress is visible to a memory-pressure unload")
    func activeRunIsVisible() {
        var use = ModelUse()
        #expect(!use.isActive)
        use.begin()
        // What stops a memory warning from taking the weights out from under
        // someone mid-sentence.
        #expect(use.isActive)
        use.end()
        #expect(!use.isActive)
    }

    @Test("Dictation is given longer than the voices")
    func deadlinesAreOrdered() {
        // The ordering is the policy: a hotkey has nowhere to put a reload,
        // and a press on Listen already waits on a progress bar.
        #expect(ModelIdle.voice < ModelIdle.supertonic)
        #expect(ModelIdle.supertonic < ModelIdle.transcription)
    }
}
