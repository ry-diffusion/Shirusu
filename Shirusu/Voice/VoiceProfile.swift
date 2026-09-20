import Foundation
import Observation

/// A voice someone saved: a reference recording, and what it is called.
///
/// Before this, a copied voice was whatever file happened to be selected in the
/// picker — gone the moment the app closed, and re-chosen from a Finder dialog
/// every session. A profile is the same recording with a name on it.
nonisolated struct VoiceProfile: Codable, Identifiable, Sendable, Equatable {
    /// What a check of the recording found. Absent when it was never run,
    /// which is the case for a file imported from disk.
    nonisolated struct Check: Codable, Sendable, Equatable {
        /// The line the person was asked to read.
        var script: String
        /// What the transcriber heard back.
        var heard: String
        /// How much of the script came back, 0...1.
        var accuracy: Double

        /// The bar a recording has to clear to be called good.
        ///
        /// Deliberately not 1: the transcriber punctuates differently, drops a
        /// clitic, and hears "pra" for "para". Those are its errors, not the
        /// speaker's, and failing someone for them would teach them to distrust
        /// the check.
        static let passMark = 0.75

        var isGood: Bool { accuracy >= Self.passMark }
    }

    let id: UUID
    var name: String
    var createdAt: Date
    /// Seconds of reference audio held on disk.
    var duration: TimeInterval
    var check: Check?

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        duration: TimeInterval,
        check: Check? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.duration = duration
        self.check = check
    }

    /// Whether the recording is long enough for the model to condition on well.
    ///
    /// `ChatterboxTTSModel` truncates its prompt mel at ten seconds and its
    /// prompt speech tokens at six, so anything past ten only sharpens the
    /// speaker embedding. Under six and the tokens are padded instead.
    var isLongEnough: Bool { duration >= 6 }
}

/// The saved voices, on disk and in memory.
///
/// One folder per profile, its JSON beside the audio it describes, so a voice
/// can be copied to another Mac, backed up, or thrown away in Finder without
/// the app's help — and so a half-written profile is one unreadable folder
/// rather than a corrupt index of all of them.
@MainActor
@Observable
final class VoiceProfiles {
    private(set) var all: [VoiceProfile] = []

    /// The profile a new run should use, remembered across launches.
    var selection: VoiceProfile.ID? {
        didSet {
            UserDefaults.standard.set(selection?.uuidString, forKey: Self.selectionKey)
        }
    }

    var selected: VoiceProfile? {
        guard let selection else { return nil }
        return all.first { $0.id == selection }
    }

    private static let selectionKey = "voiceProfile"
    private static let audioName = "reference.wav"
    private static let metadataName = "profile.json"

    init() {
        if let stored = UserDefaults.standard.string(forKey: Self.selectionKey) {
            selection = UUID(uuidString: stored)
        }
        reload()
    }

    /// The directory a profile's files live in, whether or not it exists yet.
    func directory(for id: VoiceProfile.ID) -> URL {
        Self.root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    /// The reference recording itself, for handing to the model.
    func reference(for id: VoiceProfile.ID) -> URL {
        directory(for: id).appending(path: Self.audioName)
    }

    func reload() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.root, includingPropertiesForKeys: nil)) ?? []

        all = contents
            .compactMap { folder -> VoiceProfile? in
                let metadata = folder.appending(path: Self.metadataName)
                guard let data = try? Data(contentsOf: metadata) else { return nil }
                return try? JSONDecoder.voice.decode(VoiceProfile.self, from: data)
            }
            // Newest last: the list reads as the order they were made.
            .sorted { $0.createdAt < $1.createdAt }

        if let selection, !all.contains(where: { $0.id == selection }) {
            self.selection = all.last?.id
        }
    }

    /// Take `audio` under the profile's own folder and record what it is.
    ///
    /// The audio is moved rather than referenced: a profile that points at a
    /// file in Downloads is a profile that breaks the first time someone tidies
    /// up, and this one has to survive a relaunch to be worth having.
    @discardableResult
    func add(
        name: String,
        movingAudio audio: URL,
        duration: TimeInterval,
        check: VoiceProfile.Check? = nil
    ) throws -> VoiceProfile {
        let profile = VoiceProfile(
            name: Self.uniqueName(name, among: all),
            duration: duration,
            check: check)
        let folder = directory(for: profile.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let destination = folder.appending(path: Self.audioName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: audio, to: destination)
        try write(profile)

        all.append(profile)
        selection = profile.id
        return profile
    }

    func rename(_ id: VoiceProfile.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = all.firstIndex(where: { $0.id == id }) else { return }
        var profile = all[index]
        guard profile.name != trimmed else { return }
        profile.name = Self.uniqueName(trimmed, among: all.filter { $0.id != id })
        all[index] = profile
        try? write(profile)
    }

    func remove(_ id: VoiceProfile.ID) {
        try? FileManager.default.removeItem(at: directory(for: id))
        all.removeAll { $0.id == id }
        if selection == id { selection = all.last?.id }
    }

    private func write(_ profile: VoiceProfile) throws {
        let data = try JSONEncoder.voice.encode(profile)
        try data.write(to: directory(for: profile.id).appending(path: Self.metadataName), options: .atomic)
    }

    /// "Minha voz", then "Minha voz 2". Two profiles with one name is a picker
    /// where you cannot tell which is which.
    private static func uniqueName(_ wanted: String, among others: [VoiceProfile]) -> String {
        let trimmed = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? String(localized: "Voice") : trimmed
        let taken = Set(others.map(\.name))
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    private static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appending(path: "Voices", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()
}

extension JSONEncoder {
    /// Sorted and pretty so a profile stays readable in Finder, which is half
    /// the point of keeping them as files.
    fileprivate static var voice: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var voice: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
