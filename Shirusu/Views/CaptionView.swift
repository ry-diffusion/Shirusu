import SwiftUI

/// A one-line caption bar that floats over whatever you are doing.
///
/// A capsule on Liquid Glass — Apple's own material, not a hand-rolled blur — so
/// it takes on whatever is behind it and stays legible over a bright document or
/// a dark editor alike.
///
/// The same bar serves two modes that want opposite things from it. Dictation is
/// a key you are holding down right now, so the bar confirms it: it says
/// "Listening" before the first word lands and wears a moving ring while the key
/// is down. Live captions are left on for an hour while you do something else,
/// and a surface like that has no business announcing itself — no ring, no
/// status text, and nothing on screen at all between sentences.
struct CaptionView: View {
    /// Rendered inside the window instead of floating over other apps.
    ///
    /// The floating bar disappears when there is nothing to caption. A preview
    /// that did the same would be an empty box on a settings screen, so it
    /// keeps a placeholder and stays put.
    var isPreview = false

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var session: TranscriptionSession? { app.session }
    private var isListening: Bool { session?.phase.isBusy ?? false }
    private var hasText: Bool { !(session?.transcript.isEmpty ?? true) }

    /// Whether the bar should say what it is doing.
    ///
    /// Keyed to what is actually running rather than to the selected tab. The
    /// Globe key works from anywhere now, so "which screen is showing" stopped
    /// being a reliable answer to "what is this bar for".
    private var announcesItself: Bool { !app.activity.isCaptioning }

    /// Whether there is anything worth putting on screen.
    private var isShowing: Bool {
        if isPreview { return true }
        if announcesItself { return isListening || hasText || app.activity.isWorking }
        // Live captions: only while words are actually arriving. `isSpeaking`
        // goes false a few seconds after the last new word, which is what
        // "there is nothing to caption right now" looks like from here.
        return hasText && (session?.isSpeaking ?? false)
    }

    var body: some View {
        plate
            .opacity(isShowing ? 1 : 0)
            // Invisible and still clickable would be a strip of screen that
            // swallows a drag for no reason.
            .allowsHitTesting(isShowing)
            .animation(reduceMotion ? .easeOut(duration: 0.22) : Motion.settle, value: isShowing)
    }

    private var plate: some View {
        HStack(spacing: 12) {
            indicator
            content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        // The material goes behind the content rather than over it, so the
        // plate can be thinned without taking the text down with it. `.clear`
        // is already the most transparent variant; this is the rest of the way.
        .background {
            Color.clear
                .glassEffect(.clear, in: .capsule)
                .opacity(0.78)
        }
        .overlay { rim }
        .animation(Motion.settle, value: isListening)
        .animation(Motion.settle, value: app.activity.state)
        .animation(reduceMotion ? nil : Motion.glide, value: slot)
        .padding(6)
        // Centred in a window that is larger than the plate ever gets, so the
        // plate is free to find its own width without the window moving.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Which rim, if any.
    ///
    /// The listening ring is only there while a key is being held. On a bar
    /// left on all day it would be a light turning in the corner of the eye for
    /// an hour, which is why live captions get no rim at all.
    @ViewBuilder
    private var rim: some View {
        switch app.activity.state {
        case .polishing:
            IntelligenceBorder().transition(.opacity)
        case .delivered:
            SettledBorder().transition(.opacity)
        default:
            if announcesItself, isListening { LiveBorder().transition(.opacity) }
        }
    }

    /// The natural width of the line, measured by it and reported back up.
    @State private var lineWidth: CGFloat = 0

    /// What the text gets, and so — once the padding is added — what the plate
    /// is.
    ///
    /// Sized to the sentence rather than to the window. A fixed plate held
    /// still, which was the point, but it held still at forty per cent of the
    /// screen with a half-empty bar to show for it. What makes fitting the text
    /// workable now is that the line has a bottom: it is cut at the last full
    /// stop, so it empties once a sentence and the plate comes back down with
    /// it. Before that cut the line only ever grew, the plate grew with it, and
    /// it never returned.
    private var slot: CGFloat { min(max(lineWidth, Self.minimum), Self.maximum) }

    /// Wide enough that a two-word sentence still reads as a bar.
    private static let minimum: CGFloat = 170
    /// Past this the plate stops widening and the line pans inside it instead.
    /// A caption that keeps growing to fit eventually stops being a caption.
    private static let maximum: CGFloat = 460

    /// Only shown at rest. While listening the border says it, and a second
    /// indicator saying the same thing is one element too many on a strip of
    /// screen this small.
    @ViewBuilder
    private var indicator: some View {
        if app.activity.state == .polishing {
            // Not the waveform. That mark means "audio is being worked on", and
            // it is used for exactly that on the first-run screen and while a
            // file is being read. By this point the audio is long finished and
            // a language model is rewriting text, which is a different thing
            // and reads as the app being stuck on the wrong step.
            //
            // Sparkles because the system uses it for this, and because the rim
            // behind it is already wearing the same idea.
            IntelligenceMark()
        } else if !isListening {
            Image(systemName: "text.bubble")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let session, !session.transcript.isEmpty {
            CaptionLine(transcript: session.transcript, natural: $lineWidth, slot: slot)
        } else if announcesItself, isListening {
            Text("Listening")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
        } else if isPreview {
            Text(app.mode == .captions
                ? "Captions appear here while this is on"
                : "Hold the Globe key and speak")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
        }
    }
}

/// The sentence being spoken, on a single line.
private struct CaptionLine: View {
    var transcript: Transcript
    /// Measured here, spent by the plate above.
    @Binding var natural: CGFloat
    /// What the plate settled on. Never wider than `CaptionView.maximum`.
    var slot: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sentence: [Transcript.Word] { transcript.caption(budget: Self.budget) }

    /// Characters the plate can hold at its widest.
    ///
    /// Measured against `CaptionView.maximum`: at 14pt medium a character
    /// averages 7.4 points and each word gap costs 7, so 58 characters lands
    /// around 425 points with room to spare for a line of wide glyphs. Trimming
    /// in characters rather than in points keeps the decision in the transcript,
    /// where the punctuation is.
    private static let budget = 58

    /// How far the sentence has outgrown the plate.
    ///
    /// Zero until the plate hits its cap, and while it is zero nothing already
    /// on screen moves at all: a new word lands to the right of the ones
    /// already there and the plate opens to make room. Past the cap it becomes
    /// a pan, because the newest words are the ones worth reading and they are
    /// the ones that would otherwise be lost off the edge.
    private var overflow: CGFloat { max(0, natural - slot) }

    var body: some View {
        HStack(spacing: 7) {
            ForEach(sentence) { word in
                Text(verbatim: word.text)
                    // A notch heavier than body weight: text over a
                    // translucent surface reads thin at regular.
                    .font(.system(size: 14, weight: .medium))
                    // Small type wants a touch of positive tracking; large
                    // display type wants the opposite.
                    .tracking(0.15)
                    // White on the dark plate, always. The main window tints
                    // in-flight words with the accent, but a caption is read at
                    // a glance and a second hue there costs contrast to signal
                    // something the reader cannot act on. Opacity carries
                    // "not final yet" without touching legibility.
                    .foregroundStyle(.white.opacity(word.isSettled ? 1 : 0.62))
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.caption, value: sentence)
        // Laid out at its natural width and then moved as one piece, rather
        // than re-flowed. A line that re-flows settles each word separately,
        // which is the wobble; a line that translates keeps its spacing.
        .fixedSize()
        .geometryGroup()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { natural = $0 }
        .offset(x: -overflow)
        .animation(reduceMotion ? nil : Motion.glide, value: overflow)
        .frame(width: slot, alignment: .leading)
        // Words leave at the left, so that is the edge that softens — and only
        // once something is actually leaving, or it would dim the first letter
        // of a short sentence for no reason.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(overflow > 0 ? 0 : 1), location: 0),
                    .init(color: .black, location: overflow > 0 ? 0.09 : 0),
                    .init(color: .black, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        )
    }
}

/// A light travelling around the rim while audio is being heard.
///
/// The colour sits in the edge rather than the fill because the fill is behind
/// the text: tinting it costs contrast to say something the border can say for
/// free. And it moves because a still ring reads as decoration, while one that
/// travels reads as something happening right now.
private struct LiveBorder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    var body: some View {
        Capsule(style: .continuous)
            .strokeBorder(
                AngularGradient(
                    stops: [
                        .init(color: Ink.accent.opacity(0.06), location: 0.00),
                        .init(color: Ink.accent.opacity(0.95), location: 0.14),
                        .init(color: Ink.accent.opacity(0.35), location: 0.30),
                        .init(color: Ink.accent.opacity(0.06), location: 0.55),
                        .init(color: Ink.accent.opacity(0.06), location: 1.00),
                    ],
                    center: .center,
                    angle: .degrees(angle)
                ),
                lineWidth: 1.4
            )
            .onAppear {
                guard !reduceMotion else { return }
                // Linear and continuous: a sweep that eased would read as
                // pulsing, and pulsing means something different.
                withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
            .accessibilityHidden(true)
    }
}

/// The rim while the model is working on what was just said.
///
/// Apple Intelligence's own colours, turning faster than the listening ring, so
/// the two states are told apart by hue and by speed rather than by reading a
/// label. This one means "something is being done to your words", which is a
/// different promise from "I can hear you" and deserves to look different.
private struct IntelligenceBorder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    var body: some View {
        Capsule(style: .continuous)
            // Built exactly like the listening ring, and turned the same way:
            // the gradient's own angle moves while the capsule stays put. An
            // earlier version rotated the view instead, which spins a
            // four-hundred-point capsule about its centre and throws colour
            // well outside the plate.
            .strokeBorder(Ink.intelligenceRing(angle: angle), lineWidth: 1.4)
            .onAppear {
                guard !reduceMotion else { return }
                // Faster than listening's 2.6 s, so the two rims are told apart
                // by pace as well as by hue.
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
            .accessibilityHidden(true)
    }
}

/// The mark for "a model is working on your words".
private struct IntelligenceMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .symbolEffect(
                .variableColor.iterative, options: reduceMotion ? .nonRepeating : .repeating)
            .accessibilityHidden(true)
    }
}

/// The moment it lands.
///
/// One ring in the brand accent, and then nothing. The sweep stopping is the
/// event; a second flourish on top of the text changing underneath would be two
/// things competing to announce the same thing.
private struct SettledBorder: View {
    var body: some View {
        Capsule(style: .continuous)
            .strokeBorder(Ink.accent.opacity(0.9), lineWidth: 1.6)
            .accessibilityHidden(true)
    }
}

/// Five bars breathing in place: the same mark the first-run screen uses, so
/// "working on it" looks like one idea across the app.
struct BreathingWaveform: View {
    var tint: Color = .white

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: 2.5, height: isBreathing ? heights[index] : 3)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.62)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.08),
                        value: isBreathing
                    )
            }
        }
        .frame(width: 22, height: 18)
        .onAppear { isBreathing = true }
        .accessibilityHidden(true)
    }

    private let heights: [CGFloat] = [7, 13, 18, 11, 6]
}

#Preview("Caption") {
    CaptionView()
        .environment(AppModel())
        .frame(width: 700, height: 70)
}
