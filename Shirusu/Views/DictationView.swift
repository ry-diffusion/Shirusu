import AVFoundation
import SwiftUI

/// Dictation: hold the Globe key, speak, and the words are typed where the
/// cursor already is.
struct DictationView: View {
    @Environment(AppModel.self) private var app

    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        Form {
            Section {
                HowItWorks()
                HoldToTalk()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            } footer: {
                Text("The button does the same thing as the key, for when the key is not set up yet.")
            }

            Section {
                Picker("When I let go", selection: Bindable(app).delivery) {
                    ForEach(AppModel.Delivery.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } footer: {
                Text(app.delivery == .insert
                    ? "The text is pasted into whatever app had focus. Your clipboard is put back afterwards."
                    : "Nothing is typed for you. The text waits on the clipboard until you paste it.")
            }

            Section("Globe key") {
                HotkeyBadge()
            }

            Section {
                InputDevicePicker()
                if microphone != .authorized {
                    MicrophoneRow(status: microphone) {
                        Task { microphone = await MicrophoneFeed.requestAccess() ? .authorized : .denied }
                    }
                }
            }

            if let last = app.lastDictation {
                Section("Last dictation") {
                    Text(last)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Ink.canvas)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let last = app.lastDictation { app.copyToClipboard(last) }
                } label: {
                    Label("Copy last dictation", systemImage: "document.on.document")
                }
                .disabled(app.lastDictation == nil)
            }
        }
        .onAppear { microphone = AVCaptureDevice.authorizationStatus(for: .audio) }
    }
}

/// Three steps, because that is genuinely all of it.
private struct HowItWorks: View {
    private static let steps: [(symbol: String, text: LocalizedStringKey)] = [
        ("globe", "Hold the Globe key, wherever you are."),
        ("waveform", "Speak. The bar shows what has been heard so far."),
        ("text.cursor", "Let go, and the words are typed where your cursor is."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.steps, id: \.symbol) { step in
                HStack(alignment: .firstTextBaseline, spacing: 11) {
                    Image(systemName: step.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.accent)
                        .frame(width: 18)
                    Text(step.text)
                        .font(.system(size: 13))
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MicrophoneRow: View {
    var status: AVAuthorizationStatus
    var request: () -> Void

    var body: some View {
        switch status {
        case .notDetermined:
            VStack(alignment: .leading, spacing: 6) {
                Text("Shirusu has not asked for the microphone yet.")
                    .font(.system(size: 12))
                Button("Ask now", action: request)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Label("Microphone access is off", systemImage: "mic.slash.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                Text("Turn it on for Shirusu in Privacy and Security settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
