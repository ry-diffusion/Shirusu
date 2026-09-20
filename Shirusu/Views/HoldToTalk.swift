import SwiftUI

/// Push-to-talk in the window, for when the Globe key is not an option.
///
/// The key needs Accessibility permission, and permission is exactly the thing
/// a new user has not granted yet. Without this, dictation is a screen
/// explaining a feature you cannot try.
///
/// It captures on press rather than on click, because that is what a
/// hold-to-talk control is. Waiting for the release would mean the first word
/// is always lost.
struct HoldToTalk: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHeld = false

    private var isBusy: Bool { app.session?.phase.isBusy ?? false }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isBusy ? "waveform" : "mic.fill")
                .font(Typeface.body.weight(.medium))
                .contentTransition(.symbolEffect(.replace))

            Text(isBusy ? "Listening, let go to finish" : "Hold to talk")
                .font(Typeface.body.weight(.medium))

            if isBusy, let session = app.session {
                LevelMeter(level: session.level, isLive: true)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background {
            Capsule(style: .continuous)
                .fill(Ink.accent.opacity(isHeld ? 1 : 0.88))
        }
        // A physical push. The press is already doing something, so this only
        // has to confirm that the finger landed.
        .scaleEffect(isHeld && !reduceMotion ? 0.975 : 1)
        .animation(.easeOut(duration: 0.12), value: isHeld)
        .animation(Motion.settle, value: isBusy)
        .contentShape(Capsule(style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isHeld else { return }
                    isHeld = true
                    app.showCaptions()
                    app.beginCapture(.dictation)
                }
                .onEnded { _ in
                    guard isHeld else { return }
                    isHeld = false
                    // Only finish a run this button actually started. Live
                    // captions hold the one session too, and without this a
                    // tap here stopped them — leaving the switch on over a bar
                    // showing nothing. The Globe key has always checked.
                    guard app.activity.state == .dictating else { return }
                    guard let session = app.session, session.phase.isBusy else {
                        app.activity.move(to: .idle)
                        app.captions.hide(after: 0.6)
                        return
                    }
                    app.activity.move(to: .transcribing)
                    session.stop()
                    app.captions.hide(after: app.isRambler ? 12 : 2)
                }
        )
        .accessibilityLabel(Text("Hold to talk"))
        .accessibilityHint(Text("Captures while held, and transcribes when released."))
    }
}
