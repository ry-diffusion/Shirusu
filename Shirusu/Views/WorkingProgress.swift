import SwiftUI

/// A bar, a spinner and a line saying where the work has got to.
///
/// Extracted from the first-run screen because the same thing happens later:
/// copying a voice fetches its own multi-gigabyte bundle the first time, and
/// that was reported as a percentage crammed into the Listen button. A download
/// that size deserves the shape the app already uses for one.
///
/// The spinner earns its place where the bar cannot: a fraction sits still
/// through compiling and loading, and a still bar reads as stalled.
struct WorkingProgress: View {
    var fraction: Double
    var status: String

    /// Wide enough to sit alone on a setup screen, or `nil` to fill a form row.
    var width: CGFloat?

    init(fraction: Double, status: String, width: CGFloat? = nil) {
        self.fraction = fraction
        self.status = status
        self.width = width
    }

    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(Ink.accent)
                .frame(width: width)

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(status)
                    .font(Typeface.secondary.monospaced())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(Motion.settle, value: status)
            }
        }
    }
}
