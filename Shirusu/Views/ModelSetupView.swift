import SwiftUI

/// First run. The model has to come down before anything else can happen, so this
/// screen's only job is to say what is happening and roughly how far along it is.
struct ModelSetupView: View {
    var isFirstInstall: Bool
    var step: ModelSetup.Step
    var fraction: Double

    var body: some View {
        VStack(spacing: 0) {
            AppMark(size: 104)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)

            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.2)
                .padding(.top, 26)

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 7)

            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(Ink.accent)
                .frame(width: 300)
                .padding(.top, 30)

            Text(statusLine)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(Motion.settle, value: statusLine)
                .padding(.top, 12)

            Text("Text to Speech does not use this model, and works now.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var title: String {
        isFirstInstall
            ? String(
                localized: "Downloading the model for the first time",
                comment: "First-run title while the speech model downloads")
            : String(
                localized: "Getting ready",
                comment: "Title while an already-downloaded model loads")
    }

    private var subtitle: String {
        isFirstInstall
            ? String(
                localized: "Shirusu is fetching Nemotron, the speech model it transcribes with. This happens once. Afterwards everything runs on this Mac, with nothing sent anywhere.",
                comment: "Explains the one-time model download")
            : String(
                localized: "Loading Nemotron onto the Neural Engine.",
                comment: "Shown while a cached model is loaded")
    }

    private var statusLine: String {
        switch step {
        case .checking:
            return String(localized: "Checking what is already here", comment: "Setup step")
        case .listing:
            return String(localized: "Listing model files", comment: "Setup step")
        case .downloading(let completed, let total):
            return String(
                localized: "Downloading \(completed) of \(total) files", comment: "Setup step")
        case .compiling(let model):
            return String(localized: "Compiling \(model)", comment: "Setup step")
        case .loading:
            return String(localized: "Loading the model", comment: "Setup step")
        }
    }
}

/// Setup failed. Say what broke and offer the one useful action.
struct SetupFailureView: View {
    var message: String
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)

            Text("Shirusu could not prepare the model")
                .font(.system(size: 19, weight: .semibold))
                .tracking(-0.2)
                .padding(.top, 20)

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.top, 8)

            Button("Try again", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(Ink.accent)
                .controlSize(.large)
                .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

#Preview("First run") {
    ModelSetupView(
        isFirstInstall: true,
        step: .downloading(completed: 3, total: 7),
        fraction: 0.42
    )
    .frame(width: 780, height: 580)
}

#Preview("Setup failed") {
    SetupFailureView(message: "A server with the specified hostname could not be found.") {}
        .frame(width: 780, height: 580)
}
