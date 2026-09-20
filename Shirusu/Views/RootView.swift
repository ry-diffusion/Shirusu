import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Workbench()
            .background(Ink.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) { ActivityStrip() }
            .animation(Motion.settle, value: app.stage)
            .animation(Motion.settle, value: app.speech.phase)
            .task { await app.bootstrap() }
    }
}

/// One engine, three jobs, one per screen.
///
/// A sidebar rather than a segmented control in the toolbar, because these are
/// not three views of the same thing: transcribing a file has a document and a
/// result, while captions and dictation are settings-and-status screens for a
/// feature that lives outside this window. A segmented control would promise
/// they were interchangeable.
private struct Workbench: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app

        NavigationSplitView {
            List(selection: $app.mode) {
                ForEach(AppModel.Mode.allCases) { mode in
                    HStack {
                        Label(mode.label, systemImage: mode.symbol)
                        // Captions keep running when you navigate away, so the
                        // row has to say they are running. A microphone you
                        // have forgotten about is the thing to avoid here.
                        if mode == .captions, app.isCaptioning {
                            Spacer()
                            Circle()
                                .fill(Ink.accent)
                                .frame(width: 6, height: 6)
                                .accessibilityLabel(Text("Running"))
                        }
                    }
                    .tag(mode)
                }
            }
            .navigationSplitViewColumnWidth(min: 176, ideal: 188, max: 240)
        } detail: {
            detail
                .navigationTitle(app.mode.label)
        }
        // Switching modes is a change of task, not a journey across the screen,
        // so the screens cross-fade in place rather than sliding past each
        // other. Sliding would imply the sidebar is a position in a sequence.
        .animation(Motion.settle, value: app.mode)
        .animation(Motion.settle, value: app.stage)
    }

    /// The window opens straight away, and the download takes the detail pane
    /// rather than the screen.
    ///
    /// Text to Speech has nothing to do with the transcription model, so it is
    /// fully usable while Nemotron comes down — which is the point: a first
    /// launch used to be a progress bar you could only watch.
    @ViewBuilder
    private var detail: some View {
        switch app.mode {
        case .speech:
            TextToSpeechView()
        case .transcribe:
            if let fileSession = app.fileSession {
                TranscribeView(session: fileSession)
            } else {
                setup
            }
        case .captions:
            if app.stage == .ready { CaptionsView() } else { setup }
        case .dictation:
            if app.stage == .ready { DictationView() } else { setup }
        }
    }

    @ViewBuilder
    private var setup: some View {
        switch app.stage {
        case .failed(let message):
            SetupFailureView(message: message) { app.retry() }
        case .preparing, .ready:
            // `.ready` with no file session yet is the sliver between the model
            // landing and the sessions being built. It reads as still going,
            // which is what it is.
            ModelSetupView(
                isFirstInstall: app.isFirstInstall,
                step: app.setupStep,
                fraction: app.setupFraction
            )
        }
    }
}
