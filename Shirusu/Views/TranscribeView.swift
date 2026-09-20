import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Transcribe: a recording in, text out.
///
/// The one mode with a document. The other two are live and leave nothing
/// behind; this one has a file, a result, and something worth copying.
struct TranscribeView: View {
    var session: TranscriptionSession

    @Environment(AppModel.self) private var app

    @State private var isImporting = false
    @State private var isDropTargeted = false
    @State private var pace: FileFeed.Pace = .realtime
    @State private var problem: String?

    var body: some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) { controlBar }
            .background(Ink.canvas)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                open(url)
                return true
            } isTargeted: { targeted in
                withAnimation(Motion.settle) { isDropTargeted = targeted }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.audio, .mpeg4Audio, .wav, .aiff, .mp3]
            ) { result in
                if case .success(let url) = result { open(url) }
            }
            .toolbar { toolbarItems }
            .alert(
                Text("Could not start"),
                isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
            ) {
                Button("OK", role: .cancel) { problem = nil }
            } message: {
                Text(problem ?? "")
            }
            .onChange(of: session.phase) {
                if case .failed(let message) = session.phase { problem = message }
            }
            .onChange(of: app.captureProblem) {
                if let trouble = app.captureProblem {
                    problem = trouble.message
                    app.clearCaptureProblem()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if session.transcript.isEmpty, session.phase.isBusy {
            WarmingUpStage()
        } else if session.transcript.isEmpty {
            EmptyStage(isDropTargeted: isDropTargeted) { isImporting = true }
        } else {
            TranscriptView(transcript: session.transcript, isLive: session.phase == .running)
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if let label = session.sourceLabel, session.phase.isBusy || !session.transcript.isEmpty {
                // macOS 27 wraps a toolbar item in glass at exactly its own
                // size, so a bare Text ends up with the capsule against the
                // letterforms. The breathing room has to come from here.
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                app.copyToClipboard(session.transcript.plainText)
            } label: {
                Label("Copy transcript", systemImage: "document.on.document")
            }
            .disabled(session.transcript.isEmpty)

            Button {
                session.clear()
            } label: {
                Label("Clear", systemImage: "eraser")
            }
            .disabled(session.transcript.isEmpty || session.phase.isBusy)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button {
                isImporting = true
            } label: {
                Label("Open audio", systemImage: "waveform")
                    .frame(minWidth: 62)
            }
            .buttonStyle(.borderedProminent)
            .tint(Ink.accent)
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)
            .disabled(session.phase.isBusy)

            if session.phase.isBusy {
                Button("Stop") { session.stop() }
                    .controlSize(.large)
            }

            Picker("Playback pace", selection: $pace) {
                Text("Real time").tag(FileFeed.Pace.realtime)
                Text("Fast").tag(FileFeed.Pace.fast)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(session.phase.isBusy)
            .help(Text("How quickly the file is fed to the recogniser. Real time plays it back as you read along."))

            Spacer(minLength: 8)

            if session.phase.isBusy || session.position > 0 {
                Text(timeLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(Motion.settle, value: timeLabel)
            }

            LevelMeter(level: session.level, isLive: session.phase == .running)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Ink.hairline).frame(height: 1) }
    }

    private var timeLabel: String {
        let elapsed = Self.clock(session.position)
        guard let duration = session.duration else { return elapsed }
        return "\(elapsed) / \(Self.clock(duration))"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func open(_ url: URL) {
        guard !session.phase.isBusy else { return }
        Task {
            do {
                let feed = try await FileFeed.load(url: url, pace: pace)
                session.start(feed)
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// Nothing transcribed yet. Say what to do, and make the drop target obvious
/// enough that the instruction is almost redundant.
private struct EmptyStage: View {
    var isDropTargeted: Bool
    var chooseFile: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(isDropTargeted ? Ink.accent : Color.secondary)

            Text("Drop an audio file here")
                .font(.system(size: 17, weight: .medium))
                .tracking(-0.1)

            Text("Everything runs on this Mac. To speak instead of opening a file, switch to Dictation.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Button("Choose a file", action: chooseFile)
                .buttonStyle(.link)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background {
            RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Ink.accent : Ink.hairline,
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [7, 6])
                )
                .padding(24)
        }
        .scaleEffect(isDropTargeted ? 1.012 : 1)
        .animation(Motion.settle, value: isDropTargeted)
    }
}

/// Audio is flowing but no words have landed yet. The recogniser needs a couple
/// of seconds of context before its first guess, and an unexplained empty page
/// reads as a hang.
private struct WarmingUpStage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Ink.accent)
                .opacity(isBreathing ? 1 : 0.45)
                .animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                    value: isBreathing
                )
                .onAppear { isBreathing = true }

            Text("Listening")
                .font(.system(size: 17, weight: .medium))
                .tracking(-0.1)

            Text("The first words land after a few seconds, once the model has enough context to commit.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

#Preview("Empty") {
    EmptyStage(isDropTargeted: false) {}
        .frame(width: 780, height: 500)
        .background(Ink.canvas)
}

#Preview("Warming up") {
    WarmingUpStage()
        .frame(width: 780, height: 500)
        .background(Ink.canvas)
}
