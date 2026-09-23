import FluidAudio
import Foundation
import Observation

/// Model choices and the source used for future Hugging Face requests.
@MainActor
@Observable
final class ModelPreferences {
    private static let mirrorKey = "useHFMirror"
    private static let supertonicKey = "enableSupertonic"
    private static let chatterboxKey = "enableChatterbox"
    private static let voxcpmKey = "enableVoxCPM"

    var useHFMirror = UserDefaults.standard.bool(forKey: ModelPreferences.mirrorKey) {
        didSet {
            UserDefaults.standard.set(useHFMirror, forKey: Self.mirrorKey)
            applyEndpoint()
        }
    }

    var enableSupertonic = ModelPreferences.storedEnabled(ModelPreferences.supertonicKey) {
        didSet { UserDefaults.standard.set(enableSupertonic, forKey: Self.supertonicKey) }
    }
    var enableChatterbox = ModelPreferences.storedEnabled(ModelPreferences.chatterboxKey) {
        didSet { UserDefaults.standard.set(enableChatterbox, forKey: Self.chatterboxKey) }
    }
    var enableVoxCPM = ModelPreferences.storedEnabled(ModelPreferences.voxcpmKey) {
        didSet { UserDefaults.standard.set(enableVoxCPM, forKey: Self.voxcpmKey) }
    }

    var availableBackends: [SpeechBackend] {
        var backends: [SpeechBackend] = []
        if enableSupertonic { backends.append(.supertonic3) }
        if enableChatterbox || enableVoxCPM { backends.append(.mlxAudio) }
        if enableVoxCPM { backends.append(.voiceDesign) }
        return backends
    }

    var availableCloningEngines: [CloningEngine] {
        var engines: [CloningEngine] = []
        if enableChatterbox { engines.append(.quick) }
        if enableVoxCPM { engines.append(.detailed) }
        return engines
    }

    init() { applyEndpoint() }

    private static func storedEnabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private func applyEndpoint() {
        let endpoint = useHFMirror ? "https://hf-mirror.com" : "https://huggingface.co"
        ModelRegistry.baseURL = endpoint
        // speech-swift reads HF_ENDPOINT for Chatterbox and VoxCPM. It checks
        // the process environment at request time, so the same preference can
        // cover both download libraries without moving their caches.
        setenv("HF_ENDPOINT", endpoint, 1)
    }
}
