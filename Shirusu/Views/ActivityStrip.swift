import SwiftUI

/// One place for everything that takes time, at the bottom of the window.
///
/// Two different downloads used to report themselves two different ways: the
/// transcription model took the whole screen, and the voice model — 1.7 GB of
/// it — was a percentage inside the Listen button. Neither was visible from
/// anywhere else, so switching screens looked like the work had stopped.
///
/// A determinate bar only when there is a real fraction behind it. Nothing is
/// invented to fill the space.
struct ActivityStrip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if showsSetup || showsVoice {
            VStack(spacing: 0) {
                Divider()
                if showsSetup { row(setup) }
                if showsVoice { row(voice) }
            }
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private struct Work {
        var title: LocalizedStringKey
        var detail: String
        /// Absent when nothing knows how far along this is.
        var fraction: Double?
    }

    /// The transcription model, but only where the screen is not already saying
    /// so. Transcribe, Captions and Dictation show the setup in their own
    /// detail pane while they wait; repeating it here would be two bars for one
    /// download.
    private var showsSetup: Bool {
        app.stage == .preparing && app.mode == .speech
    }

    private var showsVoice: Bool {
        app.speech.phase == .preparing || app.speech.phase == .synthesizing
    }

    private var setup: Work {
        Work(
            title: "Preparing Shirusu",
            detail: app.setupStep.detail,
            fraction: app.setupFraction)
    }

    private var voice: Work {
        // Synthesis reports no progress of its own, so it gets a spinner and no
        // bar rather than a bar that would have to be made up.
        let isPreparing = app.speech.phase == .preparing
        return Work(
            title: isPreparing ? "Getting the voice ready" : "Creating the voice",
            detail: isPreparing
                ? String(localized: "Downloading the model this voice needs. It stays on this Mac.")
                : String(localized: "Reading your text."),
            fraction: isPreparing ? app.speech.downloadFraction : nil)
    }

    private func row(_ work: Work) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)

                VStack(alignment: .leading, spacing: 1) {
                    Text(work.title)
                        .font(Typeface.secondary.weight(.medium))
                        .lineLimit(1)
                    Text(work.detail)
                        .font(Typeface.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if let fraction = work.fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(Typeface.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(Motion.settle, value: fraction)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if let fraction = work.fraction {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.08))
                        Rectangle()
                            .fill(Ink.accent)
                            .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                    }
                }
                .frame(height: 3)
                .animation(Motion.settle, value: fraction)
            }
        }
    }
}
