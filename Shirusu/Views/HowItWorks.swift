import SwiftUI

/// Three steps, in the order someone performs them.
///
/// The pattern started on the Dictation screen and is the answer to a problem
/// all three live screens share: they open on a form of settings for a feature
/// that happens somewhere else, so without this the first thing a new person
/// reads is a tuning control for something they have never seen work.
struct HowItWorks: View {
    enum Feature {
        case dictation
        case captions
        case speech
    }

    private struct Step: Identifiable {
        let id = UUID()
        let symbol: String
        let text: LocalizedStringKey
    }

    private let feature: Feature

    init(_ feature: Feature) {
        self.feature = feature
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 11) {
                    Image(systemName: step.symbol)
                        .font(Typeface.body)
                        .foregroundStyle(Ink.accent)
                        .frame(width: 18)
                    Text(step.text)
                        .font(Typeface.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var steps: [Step] {
        switch feature {
        case .dictation:
            [
                Step(symbol: "globe", text: "Hold the Globe key, wherever you are."),
                Step(symbol: "waveform", text: "Speak. The bar shows what has been heard so far."),
                Step(symbol: "text.cursor", text: "Let go, and the words are typed where your cursor is."),
            ]
        case .captions:
            [
                Step(symbol: "switch.2", text: "Turn live captions on."),
                Step(symbol: "speaker.wave.2", text: "Choose whether to follow this Mac or the room."),
                Step(symbol: "macwindow", text: "A bar floats above your other apps with what it hears."),
            ]
        case .speech:
            [
                Step(symbol: "text.cursor", text: "Write what the voice should say."),
                Step(symbol: "waveform", text: "Pick a ready voice, or copy one from a recording."),
                Step(symbol: "play.fill", text: "Press Listen."),
            ]
        }
    }
}
