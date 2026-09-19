import AVFoundation
import FoundationModels
import SwiftUI

/// Dictation: hold the Globe key, speak, and the words are typed where the
/// cursor already is.
struct DictationView: View {
    @Environment(AppModel.self) private var app

    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        @Bindable var app = app

        return Form {
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

            Section {
                Toggle(isOn: $app.isRambler) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rambler")
                        Text("Talk the way you think. Filler words come out, and a correction you say out loud is applied to whatever it corrected.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(Ink.accent)
                .disabled(!app.rambler.isAvailable)

                switch app.rambler.availability {
                case .available:
                    if app.isRambler {
                        Picker("How far it goes", selection: $app.ramblerStyle) {
                            ForEach(Rambler.Style.allCases) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        .pickerStyle(.menu)

                        Text(app.ramblerStyle.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        RamblerExample()
                    }
                case .unavailable(let reason):
                    RamblerUnavailable(reason: reason)
                }
            } footer: {
                Text("Apple's on-device model does the cleaning, so nothing you dictate leaves this Mac. It adds a second or two before the text is typed, and it is skipped for anything short.")
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

/// One line in, one line out. The feature is hard to describe and obvious to
/// see, so it is shown rather than explained twice.
private struct RamblerExample: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            line("You say", "um, so, send the commit to Pedro, no, to João", .secondary)
            line("Balanced gives", "Send the commit to João.", .primary)
        }
        .padding(.vertical, 2)
    }

    private func line(_ label: LocalizedStringKey, _ text: LocalizedStringKey, _ tint: HierarchicalShapeStyle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 88, alignment: .trailing)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Why the switch is off, and what to do about it, when there is something to
/// be done. Apple Intelligence is a system setting, not something this app can
/// turn on.
private struct RamblerUnavailable: View {
    var reason: SystemLanguageModel.Availability.UnavailableReason

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(explanation)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var explanation: LocalizedStringKey {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Rambler needs Apple Intelligence, which is switched off in System Settings."
        case .modelNotReady:
            return "Apple Intelligence is still downloading its model. Rambler works once that finishes."
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence, so dictation is typed exactly as spoken."
        @unknown default:
            return "Apple Intelligence is unavailable right now, so dictation is typed exactly as spoken."
        }
    }
}
