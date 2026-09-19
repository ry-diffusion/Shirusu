import SwiftUI

/// Input level as a short row of bars.
///
/// This earns its place: it is the only thing on screen that proves audio is
/// actually reaching the app, which is the first question when nothing is
/// transcribing.
struct LevelMeter: View {
    var level: Float
    var isLive: Bool

    private let bars = 14

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<bars, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(color(for: index))
                    .frame(width: 3, height: height(for: index))
            }
        }
        .frame(height: 22)
        .animation(.spring(duration: 0.16, bounce: 0), value: level)
        .animation(Motion.settle, value: isLive)
        .accessibilityHidden(true)
    }

    /// Bars near the middle run tallest, so the row reads as a waveform rather
    /// than a bar chart.
    private func height(for index: Int) -> CGFloat {
        let centre = Double(bars - 1) / 2
        let distance = abs(Double(index) - centre) / centre
        let shape = 1 - pow(distance, 1.7) * 0.72
        let floorHeight = 3.0
        guard isLive else { return floorHeight }
        let reach = 19.0 * shape * Double(min(max(level * 1.5, 0), 1))
        return floorHeight + reach
    }

    private func color(for index: Int) -> Color {
        guard isLive else { return Ink.hairline }
        return height(for: index) > 4 ? Ink.accent : Ink.accent.opacity(0.28)
    }
}
