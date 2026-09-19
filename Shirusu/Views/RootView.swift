import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            switch app.stage {
            case .preparing:
                ModelSetupView(
                    isFirstInstall: app.isFirstInstall,
                    step: app.setupStep,
                    fraction: app.setupFraction
                )
                .transition(.opacity)

            case .failed(let message):
                SetupFailureView(message: message) { app.retry() }
                    .transition(.opacity)

            case .ready:
                if let session = app.session {
                    Workbench(session: session)
                        .transition(.opacity)
                }
            }
        }
        .background(Ink.canvas)
        .animation(Motion.settle, value: app.stage)
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
    var session: TranscriptionSession

    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app

        NavigationSplitView {
            List(selection: $app.mode) {
                ForEach(AppModel.Mode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol)
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
    }

    @ViewBuilder
    private var detail: some View {
        switch app.mode {
        case .transcribe:
            TranscribeView(session: session)
        case .captions:
            CaptionsView()
        case .dictation:
            DictationView()
        }
    }
}
