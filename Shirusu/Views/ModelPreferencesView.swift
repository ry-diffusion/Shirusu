import SwiftUI

struct ModelPreferencesView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var preferences = app.modelPreferences

        Form {
            Section("Model downloads") {
                Toggle("Use hf-mirror.com", isOn: $preferences.useHFMirror)
                Text("New model downloads and update checks use the selected source. Models already on this Mac remain available offline.")
                    .font(Typeface.secondary)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Supertonic · ready voices", isOn: $preferences.enableSupertonic)
                Toggle("Chatterbox · quick voice copy", isOn: $preferences.enableChatterbox)
                Toggle("VoxCPM · detailed voice copy and voice design", isOn: $preferences.enableVoxCPM)
            } header: {
                Text("Voice models")
            } footer: {
                Text("Disabled models disappear from Text to Speech. Their downloaded files stay on this Mac, so enabling them again does not require another download.")
            }

            Section("Transcription") {
                Text("Parakeet stays enabled because transcription, captions, and dictation use it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 390)
    }
}
