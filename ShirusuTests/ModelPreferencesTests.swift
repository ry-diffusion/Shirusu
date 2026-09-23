import FluidAudio
import Foundation
import Testing

@testable import Shirusu

@Suite(.serialized)
struct ModelPreferencesTests {
    @Test("Mirror choice updates both model download routes")
    @MainActor
    func mirrorEndpoint() {
        let key = "useHFMirror"
        let savedPreference = UserDefaults.standard.object(forKey: key)
        let savedEndpoint = ProcessInfo.processInfo.environment["HF_ENDPOINT"]
        let savedRegistry = ModelRegistry.baseURL
        defer {
            if let savedPreference {
                UserDefaults.standard.set(savedPreference, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            if let savedEndpoint {
                setenv("HF_ENDPOINT", savedEndpoint, 1)
            } else {
                unsetenv("HF_ENDPOINT")
            }
            ModelRegistry.baseURL = savedRegistry
        }

        let preferences = ModelPreferences()
        preferences.useHFMirror = true
        #expect(ModelRegistry.baseURL == "https://hf-mirror.com")
        #expect(ProcessInfo.processInfo.environment["HF_ENDPOINT"] == "https://hf-mirror.com")

        preferences.useHFMirror = false
        #expect(ModelRegistry.baseURL == "https://huggingface.co")
        #expect(ProcessInfo.processInfo.environment["HF_ENDPOINT"] == "https://huggingface.co")
    }

    @Test("Voice models control only the modes they provide")
    @MainActor
    func voiceAvailability() {
        let keys = ["enableSupertonic", "enableChatterbox", "enableVoxCPM"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let savedEndpoint = ProcessInfo.processInfo.environment["HF_ENDPOINT"]
        let savedRegistry = ModelRegistry.baseURL
        defer {
            for (key, value) in zip(keys, saved) {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            if let savedEndpoint {
                setenv("HF_ENDPOINT", savedEndpoint, 1)
            } else {
                unsetenv("HF_ENDPOINT")
            }
            ModelRegistry.baseURL = savedRegistry
        }

        let preferences = ModelPreferences()
        preferences.enableSupertonic = false
        preferences.enableChatterbox = false
        preferences.enableVoxCPM = false
        #expect(preferences.availableBackends.isEmpty)
        #expect(preferences.availableCloningEngines.isEmpty)

        preferences.enableChatterbox = true
        #expect(preferences.availableBackends == [.mlxAudio])
        #expect(preferences.availableCloningEngines == [.quick])

        preferences.enableVoxCPM = true
        #expect(preferences.availableBackends == [.mlxAudio, .voiceDesign])
        #expect(preferences.availableCloningEngines == [.quick, .detailed])

        preferences.enableChatterbox = false
        #expect(preferences.availableBackends == [.mlxAudio, .voiceDesign])
        #expect(preferences.availableCloningEngines == [.detailed])

        preferences.enableSupertonic = true
        #expect(preferences.availableBackends == [.supertonic3, .mlxAudio, .voiceDesign])
    }
}
