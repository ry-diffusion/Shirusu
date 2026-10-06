import FluidAudio
import SwiftUI

/// The languages someone speaks, in the order they speak them most.
///
/// Rows rather than a multi-select because the order is the setting: the first
/// language is the one pinned, and the rest are what it should expect next.
struct LanguagePriorityList: View {
    @Binding var languages: [Language]

    var body: some View {
        Group {
            ForEach(Array(languages.enumerated()), id: \.element) { index, language in
                row(language, at: index)
            }
            .onMove { from, to in
                languages.move(fromOffsets: from, toOffset: to)
            }

            HStack {
                Menu("Add a language") {
                    ForEach(addable, id: \.self) { language in
                        Button(LanguagePriorities.name(of: language)) {
                            languages.append(language)
                        }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                .disabled(addable.isEmpty)
                Spacer()
            }
        }
        .onChange(of: languages) { _, new in
            LanguagePriorities.shared.replace(with: new)
        }
    }

    private func row(_ language: Language, at index: Int) -> some View {
        HStack(spacing: 10) {
            Text(index + 1, format: .number)
                .font(Typeface.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)

            Text(LanguagePriorities.name(of: language))

            if index == 0 {
                Label("Pinned", systemImage: "pin.fill")
                    .font(Typeface.caption)
                    .foregroundStyle(Ink.accent)
                    .labelStyle(.titleAndIcon)
            }

            Spacer()

            if index > 0 {
                Button {
                    languages.move(fromOffsets: [index], toOffset: 0)
                } label: {
                    Label("Pin", systemImage: "pin")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Make this the language you speak most")

                Button {
                    languages.swapAt(index, index - 1)
                } label: {
                    Label("Move up", systemImage: "arrow.up")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Move up")
            }

            Button {
                languages.remove(at: index)
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Remove")
        }
    }

    /// Everything Parakeet can hear that is not on the list yet, by name.
    private var addable: [Language] {
        LanguagePriorities.supported
            .filter { !languages.contains($0) }
            .sorted {
                LanguagePriorities.name(of: $0)
                    .localizedStandardCompare(LanguagePriorities.name(of: $1)) == .orderedAscending
            }
    }

    /// What the list does right now, which depends on what is on it.
    static func explanation(for languages: [Language]) -> LocalizedStringKey {
        guard let hint = LanguagePriorities.decoderHint(for: languages) else {
            return languages.isEmpty
                ? "No language chosen, so the recogniser may write in any alphabet it thinks it hears."
                : "These use different alphabets, so none is enforced and each is written in its own."
        }
        let script = switch hint.script {
        case .latin: String(localized: "Latin", comment: "Alphabet name")
        case .cyrillic: String(localized: "Cyrillic", comment: "Alphabet name")
        case .greek: String(localized: "Greek", comment: "Alphabet name")
        }
        if LanguagePriorities.filtersEnglish(for: languages) {
            return "The recogniser works out which language it hears by itself. This keeps it to the \(script) alphabet, and keeps English-only words out of French."
        }
        return "The recogniser works out which language it hears by itself. This keeps it to the \(script) alphabet, so unclear audio does not come out in another one."
    }
}

/// "Only my pinned language", and whatever it takes to get there: a download
/// the first time, and a refusal for a language Apple has no model for.
struct OneLanguageToggle: View {
    var pinned: Language?

    @State private var isOn = LanguagePriorities.shared.isOnlyPinned
    @State private var readiness: PinnedTranscriber.Readiness?
    @State private var download: Double?
    @State private var problem: String?

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { $0 ? enable() : disable() })) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Only my pinned language")
                Text(detail)
                    .font(Typeface.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(Ink.accent)
        .disabled(pinned == nil || readiness == .unsupported || download != nil)
        .task(id: pinned) { await refresh() }

        if let download {
            ProgressView(value: download) {
                Text("Downloading Apple's model for \(localeName)…")
                    .font(Typeface.caption)
            }
        }
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(Typeface.caption)
                .foregroundStyle(.orange)
        }
    }

    private var localeName: String {
        switch readiness {
        case .ready(let locale), .downloadable(let locale):
            return Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        case .unsupported, nil:
            return pinned.map(LanguagePriorities.name(of:)) ?? ""
        }
    }

    private var detail: String {
        guard pinned != nil else {
            return String(localized: "Add a language above to pin it first.")
        }
        switch readiness {
        case .unsupported:
            return String(localized: "Apple's transcriber has no model for \(localeName), so dictation keeps working it out by itself.")
        case .downloadable:
            return String(localized: "Dictation is written in \(localeName) and nothing else, by Apple's on-device transcriber instead of Parakeet. It does not mix languages: a word from another one is heard as \(localeName). Apple downloads its model the first time.")
        case .ready, nil:
            return String(localized: "Dictation is written in \(localeName) and nothing else, by Apple's on-device transcriber instead of Parakeet. It does not mix languages: a word from another one is heard as \(localeName).")
        }
    }

    private func refresh() async {
        problem = nil
        guard let pinned else {
            readiness = nil
            if isOn { disable() }
            return
        }
        readiness = await PinnedTranscriber.shared.readiness(for: pinned.rawValue)
        // A different language was pinned while this was on.
        switch readiness {
        case .unsupported where isOn: disable()
        case .downloadable where isOn: enable()
        default: break
        }
    }

    private func enable() {
        guard let pinned else { return }
        problem = nil
        Task {
            let state = await PinnedTranscriber.shared.readiness(for: pinned.rawValue)
            readiness = state
            switch state {
            case .unsupported:
                disable()
                return
            case .downloadable(let locale):
                download = 0
                defer { download = nil }
                do {
                    try await PinnedTranscriber.shared.install(locale) { fraction in
                        Task { @MainActor in download = fraction }
                    }
                } catch {
                    problem = String(localized: "The model could not be downloaded: \(error.localizedDescription)")
                    disable()
                    return
                }
                readiness = .ready(locale)
            case .ready:
                break
            }
            isOn = true
            LanguagePriorities.shared.isOnlyPinned = true
            await PinnedTranscriber.shared.warmUp(language: pinned.rawValue)
        }
    }

    private func disable() {
        isOn = false
        LanguagePriorities.shared.isOnlyPinned = false
    }
}

#Preview {
    @Previewable @State var languages: [Language] = [.portuguese, .english, .spanish]
    Form {
        Section {
            LanguagePriorityList(languages: $languages)
        } header: {
            Text("Languages I speak")
        } footer: {
            Text(LanguagePriorityList.explanation(for: languages))
        }
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 300)
}
