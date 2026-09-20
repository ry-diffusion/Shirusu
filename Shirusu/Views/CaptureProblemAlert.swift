import AppKit
import SwiftUI

/// Something a live run could not do, and where it gets fixed.
///
/// `beginCapture` already asks for the microphone at the moment someone holds
/// the button, which is the half the HIG asks for. The other half was missing:
/// a refusal only set a string, and the only screen watching that string was
/// Transcribe — the one screen where the Globe key is deliberately dead. So on
/// the two screens where a capture actually begins, being refused looked
/// exactly like nothing happening.
nonisolated struct CaptureProblem: Equatable {
    /// The System Settings pane that grants what was missing, when the answer
    /// is a permission rather than a device that is not there.
    enum Remedy: String, Equatable {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"

        var url: URL? {
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")
        }
    }

    let title: LocalizedStringKey
    let message: String
    let remedy: Remedy?

    /// A capture that never started: no microphone, or no permission to use it.
    static func listening(_ message: String, remedy: Remedy? = nil) -> CaptureProblem {
        CaptureProblem(title: "Could not start listening", message: message, remedy: remedy)
    }

    /// Words that were heard but could not be typed. They are on the clipboard,
    /// which the message says, so this is a report rather than a loss.
    static func typing(_ message: String, remedy: Remedy? = nil) -> CaptureProblem {
        CaptureProblem(title: "Could not type the text", message: message, remedy: remedy)
    }
}

extension View {
    /// Shows a live run's refusal, with a way to grant what it needs.
    func captureProblemAlert() -> some View {
        modifier(CaptureProblemAlertModifier())
    }
}

private struct CaptureProblemAlertModifier: ViewModifier {
    @Environment(AppModel.self) private var app

    @State private var problem: CaptureProblem?

    func body(content: Content) -> some View {
        content
            .alert(
                problem?.title ?? "",
                isPresented: Binding(
                    get: { problem != nil },
                    set: { if !$0 { problem = nil } }
                )
            ) {
                if let url = problem?.remedy?.url {
                    Button("Open Settings") {
                        problem = nil
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("OK", role: .cancel) { problem = nil }
            } message: {
                Text(problem?.message ?? "")
            }
            .onChange(of: app.captureProblem) {
                guard let trouble = app.captureProblem else { return }
                problem = trouble
                app.clearCaptureProblem()
            }
            // System audio asks for its own permission inside `start`, and
            // reports a refusal through the session rather than through
            // `captureProblem`. Its message already names the settings pane,
            // which is why there is no button to offer here.
            .onChange(of: app.session?.phase) {
                guard case .failed(let message) = app.session?.phase else { return }
                problem = .listening(message)
            }
    }
}
