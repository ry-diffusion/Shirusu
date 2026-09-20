import SwiftUI

/// The transcript, written out as it arrives.
///
/// Words the engine has committed to sit at full weight; the trailing hypothesis
/// stays in the accent colour until it settles. Both states are legible, which
/// matters more than the effect: an unreadable "in progress" style would make the
/// newest text, the text the user is actually watching, the hardest to read.
struct TranscriptView: View {
    var transcript: Transcript
    var isLive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                FlowLayout(spacing: 6, lineSpacing: 12) {
                    ForEach(transcript.words) { word in
                        WordView(word: word)
                            .transition(arrival)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                // Drives both the arrival of new words and the reflow of the
                // ones already there.
                .animation(reduceMotion ? .easeOut(duration: 0.18) : Motion.arrive,
                           value: transcript.words)
                // A zero-height anchor after the text: scrolling to the last word
                // would stop with it flush against the bottom edge.
                .overlay(alignment: .bottom) {
                    Color.clear.frame(height: 1).id(Anchor.bottom)
                }
            }
            .onChange(of: transcript.words.count) {
                guard isLive else { return }
                withAnimation(Motion.settle) {
                    proxy.scrollTo(Anchor.bottom, anchor: .bottom)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Reduce Motion still gets an entrance, just not one that moves or defocuses.
    private var arrival: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity
            .combined(with: .offset(y: 5))
            .combined(with: .modifier(active: Defocus(radius: 4), identity: Defocus(radius: 0)))
    }

    private enum Anchor: Hashable { case bottom }
}

/// A word arriving out of focus, as if it were still being resolved.
private struct Defocus: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

private struct WordView: View {
    let word: Transcript.Word

    // No text style sits at 21, and this is the surface the app exists to
    // show, so it keeps its size and scales from it rather than rounding to
    // the nearest style.
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 21

    var body: some View {
        Text(verbatim: word.text)
            .font(.system(size: size, weight: .regular))
            // Long-form text wants slightly looser tracking than a headline.
            .tracking(0.1)
            .foregroundStyle(word.isSettled ? Ink.settled : Ink.volatile)
            .animation(Motion.settle, value: word.isSettled)
    }
}

#Preview("Mid-transcription") {
    let transcript = Transcript()
    transcript.apply(
        confirmed: "Boa tarde, este é um teste de transcrição em tempo real do Shirusu, usando o modelo Nemotron rodando localmente neste Mac.",
        volatile: "A ideia é falar por alguns segundos e ver o texto"
    )
    return TranscriptView(transcript: transcript, isLive: true)
        .frame(width: 780, height: 420)
        .background(Ink.canvas)
}
