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
