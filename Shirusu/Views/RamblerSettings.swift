import SwiftUI

/// Where profiles are written and tried, and where the vocabulary lives.
///
/// The test area is not a nicety. A profile is a paragraph of English aimed at
/// a language model, and the only way to know whether a paragraph works is to
/// run it: writing one blind and finding out during a real dictation, into a
/// real document, is the wrong place to discover that the model ignored you.
/// Everything here runs the same code dictation runs, including the check that
/// decides whether the result is used at all.
struct RamblerSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private enum Tab: Hashable { case profiles, vocabulary }
    @State private var tab: Tab = .profiles

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                Text("Profiles").tag(Tab.profiles)
                Text("Vocabulary").tag(Tab.vocabulary)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            Group {
                switch tab {
                case .profiles: ProfileWorkbench()
                case .vocabulary: VocabularyEditor()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 720, height: 540)
        .background(Ink.canvas)
    }
}

// MARK: - Profiles

private struct ProfileWorkbench: View {
    @Environment(AppModel.self) private var app

    @State private var editing: RewriteProfile?
    @State private var sample = ""
    @State private var attempt: Rambler.Attempt?
    @State private var isRunning = false

    private var profiles: RewriteProfiles { app.profiles }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 190, idealWidth: 208, maxWidth: 260)
            detail
                .frame(minWidth: 400, maxWidth: .infinity)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { editing?.id }, set: { select($0) })) {
                Section("Built in") {
                    ForEach(RewriteProfile.builtIn) { row($0) }
                }
                if !profiles.custom.isEmpty {
                    Section("Yours") {
                        ForEach(profiles.custom) { row($0) }
                    }
                }
            }

            HStack(spacing: 6) {
                // Duplicating is the only way in. Starting from a blank prompt
                // means starting from the part that is hard to get right, and
                // the built-in directions are the ones known to work.
                Button {
                    let copy = profiles.duplicate(editing ?? profiles.selected)
                    editing = copy
                } label: {
                    Image(systemName: "plus")
                }
                .help(Text("Duplicate the selected profile"))

                Button {
                    guard let editing, !editing.isBuiltIn else { return }
                    profiles.delete(editing)
                    self.editing = nil
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(editing?.isBuiltIn ?? true)

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func row(_ profile: RewriteProfile) -> some View {
        HStack(spacing: 6) {
            Text(profile.name)
            if profile.id == profiles.selection {
                Spacer()
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.accent)
            }
        }
        .tag(profile.id)
    }

    private func select(_ id: UUID?) {
        editing = profiles.all.first { $0.id == id }
        attempt = nil
    }

    @ViewBuilder
    private var detail: some View {
        if let editing {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    editor(for: editing)
                    Divider()
                    testArea(for: editing)
                }
                .padding(16)
            }
        } else {
            VStack(spacing: 8) {
                Text("Pick a profile")
                    .font(.system(size: 15, weight: .medium))
                Text("Built-in profiles can be tried here and duplicated. A copy can be edited.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func editor(for profile: RewriteProfile) -> some View {
        let locked = profile.isBuiltIn

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Name", text: binding(for: profile, \.name))
                    .textFieldStyle(.roundedBorder)
                    .disabled(locked)

                Button("Use this") { profiles.selection = profile.id }
                    .disabled(profile.id == profiles.selection)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("What it should do")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: binding(for: profile, \.direction))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 96)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                            .overlay {
                                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                    .strokeBorder(Ink.hairline)
                            }
                    }
                    .disabled(locked)
                Text("Written to the model as an instruction. It is in English because the model's own instructions are, and mixing languages there is what made it translate.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Picker("How much it may change", selection: binding(for: profile, \.latitude)) {
                    ForEach(RewriteProfile.Latitude.allCases) { latitude in
                        Text(latitude.label).tag(latitude)
                    }
                }
                .pickerStyle(.menu)
                .disabled(locked)
                Text(profile.latitude.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            if locked {
                Label("Built in, so it cannot be edited. Duplicate it to make a version you can change.", systemImage: "lock")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func testArea(for profile: RewriteProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try it")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextEditor(text: $sample)
                .font(.system(size: 12))
                .frame(height: 64)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(Ink.hairline)
                        }
                }
                .overlay(alignment: .topLeading) {
                    if sample.isEmpty {
                        Text("Type or paste something said out loud, filler words and all.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 10) {
                Button(isRunning ? "Running…" : "Run") { run(profile) }
                    .disabled(isRunning || sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !app.rambler.isAvailable)

                if let attempt {
                    Text(verbatim: String(format: "%.2fs", attempt.seconds))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let attempt { result(attempt) }
        }
    }

    @ViewBuilder
    private func result(_ attempt: Rambler.Attempt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(attempt.output)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill((attempt.accepted ? Ink.accent : Color.orange).opacity(0.10))
                }

            // The check is the interesting part, so it is not hidden. A profile
            // whose output keeps getting turned down is a profile that needs a
            // different latitude, and there is no way to work that out from a
            // silent fallback during a real dictation.
            if attempt.accepted {
                Label("Would be used", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.accent)
            } else if let refusal = attempt.refusal {
                Label(refusal.explanation, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func run(_ profile: RewriteProfile) {
        isRunning = true
        attempt = nil
        Task {
            attempt = await app.rambler.attempt(sample, profile: profile)
            isRunning = false
        }
    }

    /// Writes straight through to the store, so a change is saved as it is
    /// typed and the test area always runs what is on screen.
    private func binding<T>(
        for profile: RewriteProfile, _ path: WritableKeyPath<RewriteProfile, T>
    ) -> Binding<T> {
        Binding(
            get: { (profiles.all.first { $0.id == profile.id } ?? profile)[keyPath: path] },
            set: { value in
                guard var current = profiles.all.first(where: { $0.id == profile.id }) else { return }
                current[keyPath: path] = value
                profiles.update(current)
                editing = current
            }
        )
    }
}

// MARK: - Vocabulary

/// Words the recogniser gets wrong, and what to write instead.
private struct VocabularyEditor: View {
    @State private var rows: [Row] = []

    private struct Row: Identifiable, Hashable {
        let id = UUID()
        var heard: String
        var write: String
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(Vocabulary.corrections.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                        HStack {
                            Text(entry.key).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                            Text(entry.value)
                            Spacer()
                        }
                        .font(.system(size: 12))
                    }
                } header: {
                    Text("Built in")
                } footer: {
                    Text("Every one of these is a string the recogniser actually produced.")
                        .font(.system(size: 10))
                }

                Section("Yours") {
                    ForEach($rows) { $row in
                        HStack(spacing: 8) {
                            TextField("heard", text: $row.heard)
                            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                            TextField("written", text: $row.write)
                            Button {
                                rows.removeAll { $0.id == row.id }
                                save()
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    }

                    Button {
                        rows.append(Row(heard: "", write: ""))
                    } label: {
                        Label("Add a word", systemImage: "plus")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .onChange(of: rows) { save() }

            Text("A whole word only, matched without case. It cannot paraphrase and it cannot touch a word that is not listed, which is the point: it runs before the model does, and it is the one step here that cannot invent anything.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .onAppear {
            rows = CustomVocabulary.shared.entries
                .sorted { $0.key < $1.key }
                .map { Row(heard: $0.key, write: $0.value) }
        }
    }

    private func save() {
        CustomVocabulary.shared.replace(
            with: Dictionary(rows.map { ($0.heard, $0.write) }, uniquingKeysWith: { _, last in last })
        )
    }
}
