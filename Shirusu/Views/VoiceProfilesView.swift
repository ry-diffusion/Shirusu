import SwiftUI
import UniformTypeIdentifiers

/// The saved voices, and the two ways to make one: read a line into the
/// microphone, or bring a file.
///
/// Recording here rather than in QuickTime buys one thing worth the code: the
/// app already has a transcriber loaded, so it can listen back and say whether
/// the words came through. A level meter only proves the microphone was on.
struct VoiceProfilesView: View {
    var language: SpeechSession.Language

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private enum Stage: Equatable {
        case list
        case reading
        case review
    }

    @State private var recorder = VoiceRecorder()
    @State private var stage: Stage = .list
    @State private var lineIndex = 0
    @State private var take: VoiceRecorder.Take?
    @State private var check: VoiceProfile.Check?
    @State private var name = ""
    @State private var isChecking = false
    @State private var isImporting = false
    @State private var renaming: VoiceProfile.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                switch stage {
                case .list: list
                case .reading: reading
                case .review: review
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 540, height: 460)
        .background(Ink.canvas)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio, .mpeg4Audio, .wav, .aiff, .mp3]
        ) { result in
            if case .success(let url) = result { Task { await importFile(url) } }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack {
            Text(title)
                .font(Typeface.heading.weight(.medium))
            Spacer()
            if stage == .list {
                Button("Done") { dismiss() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var title: LocalizedStringKey {
        switch stage {
        case .list: "Voices"
        case .reading: "Record a voice"
        case .review: "How it came out"
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch stage {
            case .list:
                Button("Record a voice…", systemImage: "mic.fill") { beginReading() }
                    .buttonStyle(.borderedProminent)
                    .tint(Ink.accent)
                Button("Import a file…") { isImporting = true }
                Spacer()

            case .reading:
                Button("Cancel") { recorder.cancel(); stage = .list }
                Spacer()
                recordButton

            case .review:
                Button("Record again") { beginReading() }
                Spacer()
                Button("Save voice") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Ink.accent)
                    .disabled(take == nil || isChecking)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: The saved voices

    @ViewBuilder
    private var list: some View {
        if app.voices.all.isEmpty {
            ContentUnavailableView(
                "No saved voices",
                systemImage: "waveform.circle",
                description: Text("Record a line or bring a recording, and it is kept here with a name on it.")
            )
        } else {
            List(selection: Binding(
                get: { app.voices.selection },
                set: { app.voices.selection = $0 }
            )) {
                ForEach(app.voices.all) { profile in
                    row(profile).tag(profile.id)
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ profile: VoiceProfile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: profile.id == app.voices.selection ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(profile.id == app.voices.selection
                    ? AnyShapeStyle(Ink.accent)
                    : AnyShapeStyle(HierarchicalShapeStyle.tertiary))

            VStack(alignment: .leading, spacing: 2) {
                if renaming == profile.id {
                    TextField("Name", text: Binding(
                        get: { profile.name },
                        set: { app.voices.rename(profile.id, to: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { renaming = nil }
                } else {
                    Text(profile.name).font(Typeface.body)
                }
                Text(summary(profile))
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button("Rename") { renaming = profile.id }
                Button("Delete", role: .destructive) { app.voices.remove(profile.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { app.voices.selection = profile.id }
    }

    private func summary(_ profile: VoiceProfile) -> String {
        var parts = [String(localized: "\(Int(profile.duration.rounded())) seconds")]
        if !profile.isLongEnough {
            parts.append(String(localized: "shorter than the model reads"))
        }
        if let check = profile.check {
            parts.append(check.isGood
                ? String(localized: "words checked out")
                : String(localized: "words did not match"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Reading a line

    @ViewBuilder
    private var reading: some View {
        VStack(spacing: 18) {
            if let line = scriptLine {
                Text(line)
                    .font(Typeface.heading)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .textSelection(.enabled)
                Button("Give me another line") { nextLine() }
                    .buttonStyle(.link)
                    .disabled(recorder.isRecording)
            } else {
                // No script in this language, so the instruction has to carry
                // what the script would have: how long, and how to speak.
                Text("Say anything in a normal voice for about ten seconds — what you had for lunch, what you are working on.")
                    .font(Typeface.heading)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            meter

            Text("Somewhere quiet, one voice, and stay about the same distance from the microphone. The model listens to the first ten seconds.")
                .font(Typeface.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if case .failed(let message) = recorder.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Typeface.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(24)
    }

    private var meter: some View {
        VStack(spacing: 8) {
            LevelMeter(level: recorder.level, isLive: recorder.isRecording)
                .frame(width: 180)
                .opacity(recorder.isRecording ? 1 : 0.3)

            Text(recorder.isRecording
                ? String(localized: "\(Int(recorder.duration)) seconds")
                : String(localized: "Not recording"))
                .font(Typeface.caption.monospacedDigit())
                .foregroundStyle(recorder.duration >= VoiceRecorder.wanted.lowerBound ? Ink.accent : .secondary)
                .contentTransition(.numericText())
                .animation(Motion.settle, value: Int(recorder.duration))
        }
    }

    private var recordButton: some View {
        Group {
            if recorder.isRecording {
                Button("Stop", systemImage: "stop.fill") { Task { await stopReading() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(recorder.duration < 1)
            } else {
                Button("Start recording", systemImage: "record.circle") {
                    Task { await recorder.start(device: app.inputs.resolve(app.inputDeviceUID)) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Ink.accent)
            }
        }
    }

    // MARK: What came back

    @ViewBuilder
    private var review: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isChecking {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Listening back…").font(Typeface.body)
                }
            } else if let check {
                Label(
                    check.isGood ? "The words came through" : "Some words did not come through",
                    systemImage: check.isGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(Typeface.body.weight(.medium))
                .foregroundStyle(check.isGood ? Ink.accent : .orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Heard back").font(Typeface.caption).foregroundStyle(.secondary)
                    Text(check.heard.isEmpty ? String(localized: "Nothing.") : check.heard)
                        .font(Typeface.body)
                        .textSelection(.enabled)
                }

                if !check.isGood {
                    Text("This still works as a voice — the check is about whether the recording is clear, not whether it is allowed. Recording again somewhere quieter usually helps.")
                        .font(Typeface.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Saved without a check: the transcription model is not ready yet, so there was nothing to listen back with.")
                    .font(Typeface.body)
                    .foregroundStyle(.secondary)
            }

            if let take, take.duration < VoiceRecorder.wanted.lowerBound {
                Label(
                    "Under six seconds. The model pads what it is missing, and the copy comes out less like you.",
                    systemImage: "clock"
                )
                .font(Typeface.caption)
                .foregroundStyle(.orange)
            }

            Divider()

            HStack {
                Text("Name").font(Typeface.body)
                TextField("My voice", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }

    // MARK: Doing things

    private var scriptLine: String? {
        let lines = EnrollmentScript.lines(for: language)
        guard !lines.isEmpty else { return nil }
        return lines[lineIndex % lines.count]
    }

    private func beginReading() {
        recorder.clearFailure()
        take = nil
        check = nil
        stage = .reading
    }

    private func nextLine() {
        lineIndex += 1
    }

    private func stopReading() async {
        guard let finished = await recorder.finish() else { return }
        take = finished
        name = defaultName
        stage = .review

        guard let script = scriptLine, let transcriber = app.transcriber else { return }
        isChecking = true
        defer { isChecking = false }
        let heard = (try? await transcriber.transcribe(finished.samples)) ?? ""
        check = VoiceProfile.Check(
            script: script,
            heard: heard,
            accuracy: EnrollmentCheck.accuracy(script: script, heard: heard))
    }

    private func save() {
        guard let take else { return }
        try? app.voices.add(
            name: name,
            movingAudio: take.url,
            duration: take.duration,
            check: check)
        self.take = nil
        check = nil
        stage = .list
    }

    private func importFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Decoded rather than copied: it gives the duration to show in the
        // list, and normalises whatever container came in to the one shape the
        // model reads anyway.
        guard let decoded = try? await AudioDecoder.decode(url) else { return }
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "shirusu-import-\(UUID().uuidString).wav")
        guard (try? WavEncoder
            .data(samples: decoded.samples, sampleRate: AudioFormats.sampleRate)
            .write(to: temporary)) != nil
        else { return }

        try? app.voices.add(
            name: url.deletingPathExtension().lastPathComponent,
            movingAudio: temporary,
            duration: decoded.duration)
    }

    private var defaultName: String {
        let taken = app.voices.all.count + 1
        return String(localized: "My voice \(taken)")
    }
}
