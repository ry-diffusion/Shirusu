import Foundation
import Observation
import Security

/// Chooses where a rewrite runs and keeps the provider-specific configuration.
///
/// Apple Intelligence remains the private, on-device option. Gemini is useful
/// for profiles that deliberately turn a short utterance into a much longer
/// document, but its API key and the dictated text must never end up in
/// `UserDefaults`: the key lives in the user's login Keychain instead.
enum RewriteProvider: String, CaseIterable, Identifiable, Sendable {
    case appleIntelligence
    case gemini

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .gemini: return "Gemini"
        }
    }
}

@MainActor
@Observable
final class ModelConfig {
    var provider: RewriteProvider = ModelConfig.storedProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: ModelConfig.providerKey) }
    }

    /// The stable name requested by the product. Keeping this as a setting also
    /// gives us an uncomplicated path if Google retires or renames a preview.
    var geminiModel: String = UserDefaults.standard.string(forKey: ModelConfig.modelKey)
        ?? "gemini-3.8-flash"
    {
        didSet { UserDefaults.standard.set(geminiModel, forKey: ModelConfig.modelKey) }
    }

    /// A generous ceiling is intentional: transform profiles may turn a spoken
    /// sentence into a full brief, specification, or email. Gemini only bills
    /// generated tokens, so this does not make ordinary clean-ups longer.
    var geminiMaximumOutputTokens: Int = {
        let saved = UserDefaults.standard.integer(forKey: ModelConfig.maximumOutputTokensKey)
        return saved == 0 ? 32_768 : saved
    }() {
        didSet {
            UserDefaults.standard.set(geminiMaximumOutputTokens, forKey: ModelConfig.maximumOutputTokensKey)
        }
    }

    /// Mirrors the Keychain state in an observable property. Reading a computed
    /// Keychain value does not create an Observation dependency, which left the
    /// Dictation screen showing “API key required” until it was recreated.
    private(set) var hasGeminiAPIKey = false

    /// Reading this is limited to the settings screen and immediately before a
    /// request; it is never copied into preferences, logging, or an error.
    var geminiAPIKey: String {
        get { Keychain.value(for: ModelConfig.keychainAccount) ?? "" }
        set {
            Keychain.set(newValue, for: ModelConfig.keychainAccount)
            hasGeminiAPIKey = !(Keychain.value(for: ModelConfig.keychainAccount) ?? "").isEmpty
        }
    }

    private static let providerKey = "rewriteProvider"
    private static let modelKey = "geminiRewriteModel"
    private static let maximumOutputTokensKey = "geminiRewriteMaximumOutputTokens"
    private static let keychainAccount = "gemini-api-key"

    private static var storedProvider: RewriteProvider {
        RewriteProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "")
            ?? .appleIntelligence
    }

    init() {
        hasGeminiAPIKey = !(Keychain.value(for: ModelConfig.keychainAccount) ?? "").isEmpty
        // `gemini-3-flash` was this setting's original default. Move that
        // default forward, while preserving an intentional preview selection.
        if geminiModel == "gemini-3-flash" {
            geminiModel = "gemini-3.8-flash"
        }
    }
}

private enum Keychain {
    private static let service = "br.com.zesmoi.Shirusu.rewrite"

    static func value(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        guard !value.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }

        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
