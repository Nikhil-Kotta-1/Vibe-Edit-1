import Foundation

extension Notification.Name {
    static let elevenLabsConfigChanged = Notification.Name("elevenLabsConfigChanged")
}

/// Keychain-backed ElevenLabs credentials: the API key (for minting conversation tokens)
/// and the configured Agent ID. Mirrors `AnthropicKeychain`.
enum ElevenLabsKeychain {
    private static let keyAccount = "elevenlabs-api-key"
    private static let agentAccount = "elevenlabs-agent-id"

    // MARK: API key

    static func saveAPIKey(_ key: String) {
        KeychainStore.save(key, account: keyAccount)
        postChange()
    }

    static func loadAPIKey() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: keyAccount)
    }

    static func deleteAPIKey() {
        KeychainStore.delete(account: keyAccount)
        postChange()
    }

    // MARK: Agent ID

    static func saveAgentId(_ id: String) {
        KeychainStore.save(id, account: agentAccount)
        postChange()
    }

    static func loadAgentId() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["ELEVENLABS_AGENT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: agentAccount)
    }

    static func deleteAgentId() {
        KeychainStore.delete(account: agentAccount)
        postChange()
    }

    private static func postChange() {
        NotificationCenter.default.post(name: .elevenLabsConfigChanged, object: nil)
    }
}
