import AppKit
import SwiftUI

/// One accent, one radius scale, one motion vocabulary. Everything in the app
/// pulls from here so the surfaces stay in agreement.
enum Ink {
    /// The blue from the app icon's waveform (#629EFC). One accent, and it is
    /// the brand's, so the window and the Dock tile agree.
    static let accent = dynamic(
        dark: NSColor(srgbRed: 0.458, green: 0.672, blue: 0.992, alpha: 1),
        light: NSColor(srgbRed: 0.129, green: 0.365, blue: 0.886, alpha: 1)
    )

    /// Text the model has committed to.
    static let settled = Color.primary

    /// Text still in flight. Dimmer, not a different hue: it is the same word,
    /// just not final yet.
    static let volatile = dynamic(
        dark: NSColor(srgbRed: 0.458, green: 0.672, blue: 0.992, alpha: 0.74),
        light: NSColor(srgbRed: 0.129, green: 0.365, blue: 0.886, alpha: 0.80)
    )

    /// Cool near-black rather than pure black, so the blue reads as deliberate
    /// and the surface keeps some depth.
    static let canvas = dynamic(
        dark: NSColor(srgbRed: 0.055, green: 0.060, blue: 0.075, alpha: 1),
        light: NSColor(srgbRed: 0.976, green: 0.977, blue: 0.984, alpha: 1)
    )

    static let hairline = Color.primary.opacity(0.09)

    /// The hues Apple Intelligence wears on its own surfaces.
    ///
    /// Borrowed rather than invented, because this really is Apple's model
    /// doing the work. A private colour would have been a second vocabulary for
    /// something the system already has a vocabulary for, and people already
    /// read this sweep as "a model is thinking".
    static let intelligence: [Color] = [
        Color(.sRGB, red: 0.98, green: 0.42, blue: 0.64),  // pink
        Color(.sRGB, red: 0.72, green: 0.35, blue: 0.96),  // violet
        Color(.sRGB, red: 0.36, green: 0.47, blue: 0.98),  // blue
        Color(.sRGB, red: 0.30, green: 0.82, blue: 0.94),  // cyan
    ]

    /// The sweep, mirrored so it closes on itself without a seam.
    ///
    /// Takes the angle rather than being rotated by the caller: turning the
    /// gradient inside a still shape is the effect. Turning the shape spins a
    /// long capsule end over end, which is a different thing entirely.
    static func intelligenceRing(angle: Double) -> AngularGradient {
        let loop = intelligence + intelligence.dropLast().reversed()
        return AngularGradient(
            stops: loop.enumerated().map { index, colour in
                .init(color: colour, location: Double(index) / Double(loop.count - 1))
            },
            center: .center,
            angle: .degrees(angle)
        )
    }

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            return isDark ? dark : light
        })
    }
}

/// One scale, built on the system's text styles.
///
/// Colour, radius and motion were centralised from the start; type was not, so
/// the app grew thirteen hardcoded point sizes across seventy-odd call sites.
/// `Font.system(size:)` is fixed at whatever number it is given, so none of
/// them answered the text size someone sets in Accessibility. These do, and
/// each one lands on the same point size its call site used before.
///
/// Named `Typeface` rather than `Type` because `Type` is how Swift spells a
/// metatype, and a design token should not have to be read twice.
enum Typeface {
    /// A first-run screen's title. 22.
    static let title = Font.title
    /// An empty stage's headline. 17.
    static let heading = Font.title2
    /// One step under a screen's own title. 15.
    static let subheading = Font.title3
    /// Ordinary text. 13.
    static let body = Font.body
    /// A form's second voice: footers, explanations, a value beside a label. 12.
    static let secondary = Font.callout
    /// Supporting detail under a control. 11.
    static let caption = Font.subheadline
    /// The quietest line that is still prose. 10.
    static let footnote = Font.footnote

    /// Sizes that stay fixed, and why.
    enum Fixed {
        /// An SF Symbol standing in for a picture rather than sitting in a
        /// sentence. It is sized to the space it fills, not to the text around
        /// it, so it has no text size to track.
        static let inlineGlyph: CGFloat = 9
        static let stageGlyph: CGFloat = 30
        static let heroGlyph: CGFloat = 34

        /// The floating caption bar measures itself against its own text to
        /// decide how wide to be. Until that measurement tracks the system text
        /// size, the text must not either, or the words outgrow the panel.
        static let barWord: CGFloat = 14
        static let barGlyph: CGFloat = 13
    }
}

/// Corner radii. The rule: surfaces 14, controls 10, anything pill-shaped is a capsule.
enum Radius {
    static let surface: CGFloat = 14
    static let control: CGFloat = 10
}

/// Springs, in Apple's damping/response vocabulary. `bounce: 0` is critically
/// damped and is the default; bounce is reserved for motion the user started
/// with a gesture.
enum Motion {
    /// Everything that just changes state.
    static let settle = Animation.spring(duration: 0.38, bounce: 0)
    /// A word arriving in the transcript. Slightly quicker so text keeps up with speech.
    static let arrive = Animation.spring(duration: 0.28, bounce: 0)
    /// Reserved for direct manipulation (drag release, flick).
    static let momentum = Animation.spring(duration: 0.4, bounce: 0.18)
}

extension EnvironmentValues {
    /// Reduce Motion means "gentler", not "none": call sites cross-fade instead
    /// of translating and blurring.
    var prefersCalmMotion: Bool { accessibilityReduceMotion }
}
