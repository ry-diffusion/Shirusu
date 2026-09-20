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
    @State private var problem: String?
    @State private var attempt = 1
    @State private var retryNote: LocalizedStringKey?
    @State private var wasSilent = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// After this many goes it stops starting over and says what it found.
    /// Looping forever on a microphone that is not working is not persistence.
    private static let maxAttempts = 3

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
        .alert(
            Text("Could not save the voice"),
            isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
        ) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
        // Closing the sheet mid-recording is the ordinary way out of it, and
        // it has to close the microphone too.
        .onDisappear { recorder.cancel() }
        .onChange(of: recorder.take?.url) { _, url in
            guard url != nil else { return }
            Task { await review() }
        }
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
                if recorder.isRecording {
                    Button("Stop") { Task { await recorder.finish() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(recorder.duration < 1)
                } else {
                    recordButton
                }

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
                FlowLayout(spacing: 6, lineSpacing: 10) {
                    ForEach(EnrollmentCheck.tokens(line)) { token in
                        Text(token.display)
                            .foregroundStyle(hasLanded(token)
                                ? AnyShapeStyle(Ink.settled)
                                : AnyShapeStyle(HierarchicalShapeStyle.quaternary))
                    }
                }
                .font(Typeface.heading)
                .frame(maxWidth: 420)
                // Each word brightens as the transcriber catches it, on the
                // same spring the transcript uses when a word arrives there.
                .animation(
                    reduceMotion ? .easeOut(duration: 0.18) : Motion.arrive,
                    value: recorder.readSoFar)

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

            // The words as they land. It is the same transcriber that decides
            // when the line is done, so this is the reason it stops, not a
            // decoration beside it.
            if recorder.isRecording, !recorder.heard.isEmpty {
                Text(recorder.heard)
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .lineLimit(2)
            }

            Text(scriptLine == nil
                ? "Somewhere quiet, one voice, and stay about the same distance from the microphone. The model listens to the first ten seconds."
                : "Somewhere quiet, one voice, and stay about the same distance from the microphone. It stops on its own once you have read the line.")
                .font(Typeface.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if let retryNote {
                Label(retryNote, systemImage: "arrow.counterclockwise")
                    .font(Typeface.caption)
                    .foregroundStyle(.orange)
            }

            if isChecking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Listening back…").font(Typeface.caption).foregroundStyle(.secondary)
                }
            }

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
        Button("Start recording", systemImage: "record.circle") {
            Task {
                await recorder.start(
                    device: app.inputs.resolve(app.inputDeviceUID),
                    script: scriptLine,
                    transcriber: app.transcriber)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(Ink.accent)
    }

    // MARK: What came back

    @ViewBuilder
    private var review: some View {
        VStack(alignment: .leading, spacing: 14) {
            if wasSilent {
                Label("Nothing reached the microphone", systemImage: "mic.slash.fill")
                    .font(Typeface.body.weight(.medium))
                    .foregroundStyle(.orange)
                Text("The recording is silent from end to end. Check that the right input is selected, and that a Bluetooth headset has finished switching to its microphone — that switch can take a few seconds and drops whatever is said during it.")
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
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

    /// Whether the transcriber has caught this word yet. Outside a recording
    /// the whole line reads at full strength: dimming a line nobody is reading
    /// would just make it hard to read.
    private func hasLanded(_ token: EnrollmentCheck.Token) -> Bool {
        guard recorder.isRecording else { return true }
        guard recorder.readSoFar.indices.contains(token.id) else { return false }
        return recorder.readSoFar[token.id]
    }

    private func beginReading() {
        recorder.clearFailure()
        take = nil
        check = nil
        wasSilent = false
        retryNote = nil
        attempt = 1
        stage = .reading
    }

    /// Go again on the same line, without making someone press a button to be
    /// told what they already heard.
    private func startOver(_ note: LocalizedStringKey) async {
        retryNote = note
        take = nil
        check = nil
        await recorder.start(
            device: app.inputs.resolve(app.inputDeviceUID),
            script: scriptLine,
            transcriber: app.transcriber)
    }

    private func nextLine() {
        lineIndex += 1
    }

    /// The take is in; decide what to say about it.
    ///
    /// The live pass drives the stop, but the stored verdict comes from one
    /// more read of the whole take — the same split the caption preview makes
    /// against the transcript it keeps.
    private func review() async {
        guard let finished = recorder.take else { return }

        // Nothing ever reached the microphone. Going again will not change
        // that, and telling someone to find a quieter room would be advice for
        // a problem they do not have.
        if finished.wasSilent {
            wasSilent = true
            land(finished, check: nil)
            return
        }

        guard let script = scriptLine, let transcriber = app.transcriber else {
            land(finished, check: nil)
            return
        }

        isChecking = true
        let heard = (try? await transcriber.transcribe(finished.heardSamples)) ?? ""
        isChecking = false

        let verdict = VoiceProfile.Check(
            script: script,
            heard: heard,
            accuracy: EnrollmentCheck.accuracy(script: script, heard: heard))

        if !verdict.isGood, attempt < Self.maxAttempts {
            attempt += 1
            await startOver(heard.isEmpty
                ? "That one did not come through at all. Going again."
                : "Some of the line was missing. Going again.")
            return
        }

        land(finished, check: verdict)
    }

    private func land(_ finished: VoiceRecorder.Take, check: VoiceProfile.Check?) {
        take = finished
        self.check = check
        name = defaultName
        retryNote = nil
        stage = .review
    }

    private func save() {
        guard let take else { return }
        do {
            try app.voices.add(
                name: name,
                movingAudio: take.url,
                duration: take.duration,
                check: check)
        } catch {
            problem = error.localizedDescription
            return
        }
        self.take = nil
        check = nil
        stage = .list
    }

    private func importFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Decoded rather than copied: it gives the duration to show in the
        // list, and normalises whatever container came in to the rate the
        // cloning model conditions at.
        guard let decoded = try? await AudioDecoder.decode(
            url, sampleRate: AudioFormats.referenceSampleRate)
        else { return }
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "shirusu-import-\(UUID().uuidString).wav")
        guard (try? WavEncoder
            .data(samples: decoded.samples, sampleRate: decoded.sampleRate)
            .write(to: temporary)) != nil
        else { return }

        do {
            try app.voices.add(
                name: url.deletingPathExtension().lastPathComponent,
                movingAudio: temporary,
                duration: decoded.duration)
        } catch {
            problem = error.localizedDescription
        }
    }

    private var defaultName: String {
        let taken = app.voices.all.count + 1
        return String(localized: "My voice \(taken)")
    }
}
