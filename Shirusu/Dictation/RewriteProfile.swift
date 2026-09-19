import Foundation
import Observation

/// One way of handling what was dictated.
///
/// The built-in styles and anything the user writes are the same kind of thing:
/// a name, a paragraph of direction for the model, and a statement of how far
/// the result may stray. Making them one type means the editor, the test area
/// and the guard all work on whatever is selected without caring where it came
/// from.
struct RewriteProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    /// What the model is told to do, in its own words.
    var direction: String
    var latitude: Latitude
    /// Built-ins can be duplicated but not edited or deleted. A profile whose
    /// behaviour the app documents has to keep behaving that way.
    var isBuiltIn: Bool = false

    /// How far the result is allowed to stray, and therefore how hard the guard
    /// checks it.
    ///
    /// Three settings rather than three percentages: the numbers underneath are
    /// tuning, and asking someone to pick a word-overlap floor is asking them to
    /// debug a heuristic they cannot see.
    enum Latitude: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Every word kept was a word that was spoken.
        case sameWords
        /// The wording may change; the length should not, much.
        case reworded
        /// The wording may change and the result should be shorter.
        case shortened

        var id: String { rawValue }

        var label: String {
            switch self {
            case .sameWords:
                return String(localized: "Keep my words", comment: "Rewrite latitude")
            case .reworded:
                return String(localized: "May reword", comment: "Rewrite latitude")
            case .shortened:
                return String(localized: "May reword and shorten", comment: "Rewrite latitude")
            }
        }

        var summary: String {
            switch self {
            case .sameWords:
                return String(
                    localized: "Only removes. Anything left standing is something you said.",
                    comment: "Rewrite latitude explanation")
            case .reworded:
                return String(
                    localized: "Can choose different words for the same thing, at about the same length.",
                    comment: "Rewrite latitude explanation")
            case .shortened:
                return String(
                    localized: "Can choose different words and cut the result down.",
                    comment: "Rewrite latitude explanation")
            }
        }

        /// Whether the words themselves may change.
        var allowsRewording: Bool { self != .sameWords }

        /// Length the result may be, as a percentage of what was said.
        var lengthBounds: (low: Int, high: Int) {
            switch self {
            case .sameWords: return (35, 118)
            case .reworded: return (40, 175)
            case .shortened: return (20, 110)
            }
        }

        /// How much of the result has to be words that were actually spoken.
        /// A rewrite is meant to change words, so this is kept above zero only
        /// to catch a reply that is about something else entirely.
        var overlapFloor: Int {
            switch self {
            case .sameWords: return 55
            case .reworded, .shortened: return 20
            }
        }
    }
}

extension RewriteProfile {
    /// The profiles that ship with the app.
    ///
    /// Every direction here is the phrasing that survived a probe of the real
    /// model. The ones that did not survive are gone: a "Light" profile that
    /// removed only filler words was written three ways, including one that
    /// listed the words to delete, and returned the text untouched every time.
    static let builtIn: [RewriteProfile] = [
        RewriteProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000FA17")!,
            name: String(localized: "Faithful", comment: "Built-in profile name"),
            direction: """
                Remove the parts that are not information: filler words, \
                stammers, false starts, and anything the speaker replaced by \
                correcting themselves out loud. Keep everything that is \
                information, and keep the speaker's own voice, register and \
                choice of words exactly as they are. Do not make it sound \
                better written than it was said.
                """,
            latitude: .sameWords,
            isBuiltIn: true
        ),
        RewriteProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000BA1A0")!,
            name: String(localized: "Balanced", comment: "Built-in profile name"),
            direction: """
                Remove filler words and false starts. Apply corrections the \
                speaker made out loud and delete what they replace; a \
                correction can come much later than the thing it corrects.
                """,
            latitude: .sameWords,
            isBuiltIn: true
        ),
        RewriteProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000A66E5510")!,
            name: String(localized: "Aggressive", comment: "Built-in profile name"),
            direction: """
                Remove filler words and false starts. Apply corrections the \
                speaker made out loud and delete what they replace. Then write \
                what is left as clean, direct sentences, in the order that \
                reads best, as though the person had written it rather than \
                said it. You may drop a point they made twice, but never one \
                they made once.
                """,
            latitude: .sameWords,
            isBuiltIn: true
        ),
        RewriteProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000F0E3A11")!,
            name: String(localized: "Formal", comment: "Built-in profile name"),
            direction: """
                Clean it up, then rewrite it in a formal register: full \
                sentences, no slang, polite without being stiff.
                """,
            latitude: .reworded,
            isBuiltIn: true
        ),
        RewriteProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000CA54A11")!,
            name: String(localized: "Casual", comment: "Built-in profile name"),
            direction: """
                Clean it up, then rewrite it casually: relaxed and \
                conversational, the way you would write to a colleague you know \
                well.
                """,
            latitude: .reworded,
            isBuiltIn: true
        ),
        RewriteProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000005407E1")!,
            name: String(localized: "Shorter", comment: "Built-in profile name"),
            direction: """
                Summarise it into the fewest words that still carry every fact, \
                name, number and request. Merging points the speaker repeated \
                is required. The result must be much shorter than the input.
                """,
            latitude: .shortened,
            isBuiltIn: true
        ),
    ]

    static var `default`: RewriteProfile { builtIn[1] }
}

/// The profiles that exist, and which one is in use.
@MainActor
@Observable
final class RewriteProfiles {
    private(set) var custom: [RewriteProfile] = []
    var selection: UUID = RewriteProfile.default.id {
        didSet { UserDefaults.standard.set(selection.uuidString, forKey: Self.selectionKey) }
    }

    /// Built-ins first, then the user's own, which is the order they were
    /// learned in.
    var all: [RewriteProfile] { RewriteProfile.builtIn + custom }

    var selected: RewriteProfile {
        all.first { $0.id == selection } ?? .default
    }

    private static let storeKey = "rewriteProfiles"
    private static let selectionKey = "rewriteProfile"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
            let saved = try? JSONDecoder().decode([RewriteProfile].self, from: data)
        {
            custom = saved
        }
        if let raw = UserDefaults.standard.string(forKey: Self.selectionKey),
            let id = UUID(uuidString: raw)
        {
            selection = id
        }
    }

    /// A copy of `profile`, editable, selected and ready to be renamed.
    ///
    /// The only way to make a profile. Starting from a blank prompt means
    /// starting from the part that is hard to get right, and the built-in
    /// directions are the ones that are known to work.
    @discardableResult
    func duplicate(_ profile: RewriteProfile) -> RewriteProfile {
        var copy = profile
        copy.id = UUID()
        copy.isBuiltIn = false
        copy.name = Self.uniqueName(basedOn: profile.name, among: all)
        custom.append(copy)
        save()
        selection = copy.id
        return copy
    }

    func update(_ profile: RewriteProfile) {
        guard !profile.isBuiltIn, let index = custom.firstIndex(where: { $0.id == profile.id })
        else { return }
        custom[index] = profile
        save()
    }

    func delete(_ profile: RewriteProfile) {
        guard !profile.isBuiltIn else { return }
        custom.removeAll { $0.id == profile.id }
        save()
        if selection == profile.id { selection = RewriteProfile.default.id }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(custom) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }

    private static func uniqueName(basedOn name: String, among existing: [RewriteProfile]) -> String {
        let taken = Set(existing.map(\.name))
        var candidate = String(localized: "\(name) copy", comment: "Name of a duplicated profile")
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(name) \(suffix)"
            suffix += 1
        }
        return candidate
    }
}
