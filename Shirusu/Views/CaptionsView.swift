import SwiftUI

/// Live Captions: a bar over everything else, following what the Mac hears.
///
/// A switch rather than a key to hold. The thing being captioned is a call, a
/// video, a voice message someone sent you, and none of those are things you
/// can hold a key through. It defaults to what the Mac is playing for the same
/// reason.
struct CaptionsView: View {
    @Environment(AppModel.self) private var app

    private var session: TranscriptionSession? { app.session }

    var body: some View {
        @Bindable var app = app

        Form {
            Section {
                HowItWorks(.captions)
            }

            Section {
                preview
                toggle
            } footer: {
                // The floating bar itself is now described in the steps above,
                // so this says only what they do not: that it survives you
                // walking away from this screen.
                Text("The bar never takes focus, so it does not interrupt what you are doing, and it keeps running while you use the rest of the app.")
            }

            Section {
                Picker("Listen to", selection: $app.captureSource) {
                    ForEach(AppModel.CaptureSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                if app.captureSource == .microphone {
                    InputDevicePicker()
                }
            } footer: {
                Text(app.captureSource == .systemAudio
                    ? "What this Mac is playing. A call, a video, a voice message."
                    : "The room, through the microphone.")
            }

            Section {
                Picker("Caption updates", selection: $app.captionUpdateRate) {
                    ForEach(AppModel.CaptionUpdateRate.allCases) { rate in
                        Text(rate.label).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint(Text("Less frequent updates use less battery."))
            } footer: {
                Text("Instant feels most responsive. Normal and Slow use less battery for long calls and videos.")
            }

            Section {
                HotkeyBadge()
            } header: {
                Text("Globe key")
            } footer: {
                Text("The Globe key dictates, from whichever screen you are on. Live captions have this switch instead, because you cannot hold a key through a film.")
            }
        }
        .captureProblemAlert()
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Ink.canvas)
    }

    private var toggle: some View {
        HStack {
            Toggle(isOn: Binding(get: { app.isCaptioning }, set: { enabled in
                app.setLiveCaptions(enabled)
            })) {
                Text("Live captions")
            }
            .toggleStyle(.switch)
            .tint(Ink.accent)

            Spacer(minLength: 12)

            // Proof it is hearing something. A caption bar that stays empty
            // because the wrong input is selected looks identical to one that
            // is broken; a moving meter tells them apart.
            if let session, app.isCaptioning {
                LevelMeter(level: session.level, isLive: true)
            }
        }
    }

    /// The real caption view on a stand-in desktop, not a drawing of it.
    ///
    /// Rendering the same component means the preview cannot drift from what
    /// actually appears, and while captions are running this is a live mirror
    /// of the bar rather than a picture of one.
    private var preview: some View {
        CaptionView(isPreview: true)
            .frame(height: 62)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
                    .fill(Color.black.opacity(0.28))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
                            .strokeBorder(Ink.hairline)
                    }
            }
            // The bar is built to read over a dark backdrop, which is the one
            // thing a light form section is not.
            .environment(\.colorScheme, .dark)
            .padding(.vertical, 4)
            .accessibilityLabel(Text("Preview of the caption bar"))
    }
}
