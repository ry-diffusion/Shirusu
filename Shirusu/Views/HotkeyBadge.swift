import AppKit
import SwiftUI

/// Whether the Globe key is actually being watched, and if not, what to do.
///
/// This used to be a toolbar icon whose state only showed on hover, which meant
/// pressing the key and getting nothing looked like a broken app rather than an
/// ungranted permission. Both live modes depend on the key, so both show this.
struct HotkeyBadge: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.hotkey.availability {
        case .active where app.hotkey.isGlobeKeyFree:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.accent)

        case .active:
            // Watching works, but macOS will swallow the press first.
            VStack(alignment: .leading, spacing: 6) {
                Label("macOS is using the Globe key", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                Text("Set “Press 🌐 to” to “Do Nothing” in Keyboard settings and the key is yours.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Open Keyboard settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }

        case .needsAccessibilityPermission:
            VStack(alignment: .leading, spacing: 6) {
                Label("Needs Accessibility permission", systemImage: "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
                Text("Reading the Globe key, and typing where your cursor is, both go through Accessibility.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Allow") { app.hotkey.requestAccessibilityPermission() }
                        .buttonStyle(.link)
                    // The list wants the app dragged in, and finding a build
                    // inside DerivedData by hand is its own small ordeal.
                    Button("Reveal app") { app.hotkey.revealInFinder() }
                        .buttonStyle(.link)
                }
                .font(.system(size: 11))
            }

        case .failed:
            Label("Unavailable on this Mac", systemImage: "globe.badge.chevron.backward")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

        case .off:
            Button {
                if !app.enableHotkey() { app.hotkey.requestAccessibilityPermission() }
            } label: {
                Label("Turn on the Globe key", systemImage: "globe")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.link)
        }
    }
}
