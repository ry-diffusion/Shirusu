import SwiftUI

/// Which microphone to listen through.
///
/// Every row carries the device's own glyph rather than one microphone icon
/// repeated down the list, because that is what makes it readable at a glance:
/// AirPods look like AirPods, and the Mac's own input looks like a microphone.
struct InputDevicePicker: View {
    @Environment(AppModel.self) private var app

    /// What "follow the system" resolves to right now, so the row is not a
    /// promise the user has to go and verify in Sound settings.
    private var systemChoice: InputDevice? {
        app.inputs.resolve(nil)
    }

    var body: some View {
        @Bindable var app = app

        Picker(selection: $app.inputDeviceUID) {
            Label(
                systemChoice.map { String(localized: "Follow the system (\($0.name))", comment: "Input device: track whatever macOS is set to") }
                    ?? String(localized: "Follow the system", comment: "Input device: track whatever macOS is set to"),
                systemImage: systemChoice?.symbol ?? "gearshape"
            )
            .tag(String?.none)

            Divider()

            ForEach(app.inputs.devices) { device in
                Label(device.name, systemImage: device.symbol)
                    .tag(String?.some(device.id))
            }
        } label: {
            Text("Microphone")
        }
        .pickerStyle(.menu)
    }
}
