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
    @State private var referenceAudio: URL?
    @State private var isImportingReference = false
    @State private var isLyricsMode = false
    @State private var lyricLines: [VoiceLine] = []
    @State private var advancedTab: AdvancedTab = .voiceCloning

    var body: some View {
        @Bindable var speech = app.speech

        Form {
            Section {
                HowItWorks(.speech)
            }

            Section {
                TextEditor(text: $text)
                    .font(.system(size: 14))
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
                        .font(.system(size: 12))
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
        .fileImporter(
            isPresented: $isImportingReference,
            allowedContentTypes: [.audio, .mpeg4Audio, .wav, .aiff, .mp3]
        ) { result in
            if case .success(let url) = result { referenceAudio = url }
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Copying a voice uses more memory than a ready voice. The first setup and long texts can take time; use short passages and keep Shirusu open for more stable results.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            slider("Expressiveness", value: $mlxAudio.exaggeration, range: 0...1, step: 0.05)
            slider("Pace", value: $mlxAudio.cfgWeight, range: 0...1, step: 0.05)
            slider("Variation", value: $mlxAudio.temperature, range: 0.05...1.5, step: 0.05)
        } header: {
            Text("Voice delivery")
        } footer: {
            Text("Expressiveness makes the interpretation more pronounced. Too much can speed up the speech or make it less natural. Start in the middle and adjust gradually.")
        }
    }

    @ViewBuilder
    private var lyricsControls: some View {
        Section {
            if referenceAudio == nil {
                Label("Choose a recording in Voice Cloning before creating the voice.", systemImage: "info.circle")
                    .font(.system(size: 12))
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
            Label("The recording voice will be used", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Ink.accent)
            if needsReference {
                if let referenceAudio {
                    LabeledContent("Selected recording", value: referenceAudio.lastPathComponent).lineLimit(1)
                    Button("Replace recording…") { isImportingReference = true }
                    Button("Remove recording", role: .destructive) { self.referenceAudio = nil }
                } else {
                    Button("Choose recording…") { isImportingReference = true }
                }
            }
        } header: {
            Text("Voice Cloning")
        } footer: {
            Text("Required. Use a clean recording with only one person speaking for 5 to 20 seconds. The recording stays on this Mac, and its temporary copy is deleted when the voice is ready. Only use your own voice or a voice you are authorized to use.")
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
        case .preparing:
            let percentage = Int((app.speech.downloadFraction * 100).rounded())
            return String(localized: "Preparing (\(percentage)%)…")
        case .synthesizing:
            return String(localized: "Creating the voice…")
        case .idle, .playing, .failed:
            return ""
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
