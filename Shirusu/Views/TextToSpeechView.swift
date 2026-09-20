import SwiftUI
import UniformTypeIdentifiers

/// Espaço separado da ditado para criar voz com calma, testar versões e usar
/// uma gravação de referência quando a pessoa quiser uma voz personalizada.
struct TextToSpeechView: View {
    private enum AdvancedTab: Hashable {
        case voiceCloning
        case lyrics
    }

    @Environment(AppModel.self) private var app

    @State private var text = ""
    @State private var backend: SpeechBackend = .supertonic3
    @State private var language: SpeechSession.Language = .portuguese
    @State private var voice: SpeechSession.Voice = .m1
    @State private var mlxAudio = MLXAudioControls()
    @State private var isManagingVoices = false
    @State private var isLyricsMode = false
    @State private var lyricLines: [VoiceLine] = []
    @State private var advancedTab: AdvancedTab = .voiceCloning

    @ScaledMetric(relativeTo: .body) private var editorSize: CGFloat = 14

    var body: some View {
        @Bindable var speech = app.speech

        Form {
            Section {
                HowItWorks(.speech)
            }

            Section {
                TextEditor(text: $text)
                    .font(.system(size: editorSize))
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .fill(.primary.opacity(0.045))
                    }
                    .accessibilityLabel(Text("Text to speak"))
            } header: {
                Text("What should the voice say?")
            } footer: {
                Text("Write a sentence, script, or lyrics. To read lyrics line by line, copy a voice below.")
            }

            Section {
                Picker("Choose a voice", selection: $backend) {
                    ForEach(SpeechBackend.allCases) { backend in
                        Text(backend.label).tag(backend)
                    }
                }
                .onChange(of: backend) { _, backend in
                    if backend != .mlxAudio { isLyricsMode = false }
                    if backend == .mlxAudio { advancedTab = .voiceCloning }
                    app.speech.prepare(for: backend)
                }

                Picker("Language", selection: $language) {
                    ForEach(SpeechSession.Language.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }

                if backend == .supertonic3 {
                    Picker("Voice", selection: $voice) {
                        ForEach(SpeechSession.Voice.allCases) { voice in
                            Text(voice.rawValue).tag(voice)
                        }
                    }
                }
            } header: {
                Text("Voice")
            } footer: {
                Text(modelDescription)
            }

            if backend == .mlxAudio {
                advancedWorkspace
            }

            if case .failed(let message) = speech.phase {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(Typeface.secondary)
                    Button("Try again") { speech.clearFailure() }
                        .buttonStyle(.link)
                }
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Ink.canvas)
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .onAppear { app.speech.prepare(for: backend) }
        .onDisappear { app.speech.stop() }
        .sheet(isPresented: $isManagingVoices) {
            VoiceProfilesView(language: language).environment(app)
        }
    }

    @ViewBuilder
    private var advancedWorkspace: some View {
        Section {
            Picker("Voice Cloning workspace", selection: $advancedTab) {
                Text("Voice Cloning").tag(AdvancedTab.voiceCloning)
                Text("Song lyrics").tag(AdvancedTab.lyrics)
            }
            .pickerStyle(.segmented)
        } footer: {
            Text("Choose one task at a time. Your recording and voice controls stay in Voice Cloning; line-by-line interpretation stays in Song lyrics.")
        }

        switch advancedTab {
        case .voiceCloning:
            voiceCloning
            advancedCloningControls
        case .lyrics:
            lyricsControls
        }
    }

    @ViewBuilder
    private var advancedCloningControls: some View {
        Section {
            Label("Heavier on your Mac", systemImage: "cpu")
                .font(Typeface.body.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Copying a voice uses more memory than a ready voice. The first setup and long texts can take time; use short passages and keep Shirusu open for more stable results.")
                .font(Typeface.secondary)
                .foregroundStyle(.secondary)
            // The same two values the Song lyrics tab already names. Having
            // them be sliders here and presets there meant one thing spoke
            // with two vocabularies depending on which tab you were on.
            Picker("Tone", selection: toneSelection) {
                ForEach(VoiceLine.Tone.allCases) { tone in
                    Text(tone.label).tag(Optional(tone))
                }
                // Only appears once a technical slider has moved the value off
                // every preset. Offering it otherwise would be a choice that
                // does nothing.
                if toneSelection.wrappedValue == nil {
                    Text("Custom").tag(VoiceLine.Tone?.none)
                }
            }
            Picker("Pace", selection: paceSelection) {
                ForEach(VoiceLine.Pace.allCases) { pace in
                    Text(pace.label).tag(Optional(pace))
                }
                if paceSelection.wrappedValue == nil {
                    Text("Custom").tag(VoiceLine.Pace?.none)
                }
            }
            slider("Variation", value: $mlxAudio.temperature, range: 0.05...1.5, step: 0.05)

            DisclosureGroup("Technical options") {
                // The model's own names, on purpose. Someone who opens this
                // drawer is looking for the values they read about, and a
                // friendly rename would only hide which knob is which.
                slider("Exaggeration", value: $mlxAudio.exaggeration, range: 0...1, step: 0.05)
                slider("CFG weight", value: $mlxAudio.cfgWeight, range: 0...1, step: 0.05)
                slider("Repetition penalty", value: $mlxAudio.repetitionPenalty, range: 1...2, step: 0.05)
                slider("Min-p", value: $mlxAudio.minP, range: 0...0.2, step: 0.01)
                slider("Top-p", value: $mlxAudio.topP, range: 0.1...1, step: 0.05)
                Button("Back to defaults") { mlxAudio = MLXAudioControls() }
                    .buttonStyle(.link)
            }
        } header: {
            Text("Voice delivery")
        } footer: {
            Text("Dramatic makes the interpretation more pronounced, and can speed the speech up or make it less natural. Variation changes how much one reading differs from the last; it is the model's temperature. Tone and Pace are named points on Exaggeration and CFG weight, so moving either below shows them as Custom.")
        }
    }

    @ViewBuilder
    private var lyricsControls: some View {
        Section {
            if referenceAudio == nil {
                Label("Choose a recording in Voice Cloning before creating the voice.", systemImage: "info.circle")
                    .font(Typeface.secondary)
                    .foregroundStyle(.secondary)
                Button("Go to Voice Cloning") { advancedTab = .voiceCloning }
            }
            Toggle("Interpret each line", isOn: $isLyricsMode)
            if isLyricsMode {
                Button("Prepare lyric lines") { lyricLines = VoiceLine.makeLines(from: text) }
                if lyricLines.isEmpty {
                    ContentUnavailableView(
                        "Prepare the lyrics",
                        systemImage: "music.note.list",
                        description: Text("Put each verse on a new line and choose “Prepare lyric lines”.")
                    )
                } else {
                    ForEach($lyricLines) { $line in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Line", text: $line.text, axis: .vertical).lineLimit(1...3)
                            HStack {
                                Picker("Tone", selection: $line.tone) {
                                    ForEach(VoiceLine.Tone.allCases) { tone in Text(tone.label).tag(tone) }
                                }
                                Picker("Pace", selection: $line.pace) {
                                    ForEach(VoiceLine.Pace.allCases) { pace in Text(pace.label).tag(pace) }
                                }
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        } header: {
            Text("Song lyrics")
        } footer: {
            Text("Each line is made separately with the selected tone and pace. This is an expressive reading: the model does not create a melody or sing the lyrics.")
        }
    }

    @ViewBuilder
    private var voiceCloning: some View {
        Section {
            if app.voices.all.isEmpty {
                Button("Record or choose a voice…") { isManagingVoices = true }
            } else {
                Picker("Voice", selection: Binding(
                    get: { app.voices.selection },
                    set: { app.voices.selection = $0 }
                )) {
                    Text("None").tag(VoiceProfile.ID?.none)
                    ForEach(app.voices.all) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                if let selected = app.voices.selected, !selected.isLongEnough {
                    Label(
                        "This recording is under six seconds, which is less than the model conditions on.",
                        systemImage: "clock"
                    )
                    .font(Typeface.caption)
                    .foregroundStyle(.orange)
                }
                Button("Manage voices…") { isManagingVoices = true }
            }
        } header: {
            Text("Voice Cloning")
        } footer: {
            Text("Required. Record a line here or bring a file: one person, somewhere quiet, six to twenty seconds. The model conditions on the first ten. Saved voices stay on this Mac. Only use your own voice or a voice you are authorized to use.")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if app.speech.isPlaying {
                Button("Stop", systemImage: "stop.fill") { app.speech.stop() }.controlSize(.large)
            } else {
                Button(action: requestSpeech) {
                    if app.speech.phase.isBusy {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                            Text(status)
                        }
                    } else {
                        Label("Listen", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Ink.accent)
                .controlSize(.large)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (backend == .mlxAudio && referenceAudio == nil))
                .allowsHitTesting(!app.speech.phase.isBusy)
            }
            Spacer()
            if app.speech.phase.isBusy { Button("Cancel") { app.speech.stop() }.controlSize(.large) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Ink.hairline).frame(height: 1) }
    }

    private var needsReference: Bool { backend == .mlxAudio }

    /// The selected profile's recording on disk, or nothing chosen yet.
    private var referenceAudio: URL? {
        app.voices.selection.map(app.voices.reference)
    }

    /// The preset whose value is currently set, or `nil` for anything else.
    /// Reading the picker off the value rather than storing it separately is
    /// what keeps the drawer and the presets from disagreeing.
    private var toneSelection: Binding<VoiceLine.Tone?> {
        Binding(
            get: { VoiceLine.Tone.allCases.first { $0.exaggeration == mlxAudio.exaggeration } },
            set: { if let tone = $0 { mlxAudio.exaggeration = tone.exaggeration } })
    }

    private var paceSelection: Binding<VoiceLine.Pace?> {
        Binding(
            get: { VoiceLine.Pace.allCases.first { $0.cfgWeight == mlxAudio.cfgWeight } },
            set: { if let pace = $0 { mlxAudio.cfgWeight = pace.cfgWeight } })
    }

    private func requestSpeech() {
        guard !app.speech.phase.isBusy else { return }
        app.speech.speak(
            text: text, backend: backend, language: language, voice: voice,
            mlxAudio: mlxAudio,
            referenceAudio: needsReference ? referenceAudio : nil,
            lyricLines: isLyricsMode ? lyricLines : []
        )
    }

    private var status: String {
        switch app.speech.phase {
        case .preparing: String(localized: "Preparing…")
        case .synthesizing: String(localized: "Creating the voice…")
        case .idle, .playing, .failed: ""
        }
    }


    private var modelDescription: String {
        switch backend {
        case .supertonic3: String(localized: "Ten voices, ready to speak. The one you pick downloads once and then works on this Mac.")
        case .mlxAudio: String(localized: "Copies the voice from a recording you choose. It adds controls for delivery and for reading lyrics line by line, and uses more memory.")
        }
    }

    private func slider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, step: Float) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step).tint(Ink.accent)
        }
    }
}

#Preview {
    TextToSpeechView().environment(AppModel()).frame(width: 780, height: 560)
}
