import Foundation

enum ElevenLabsTokenError: LocalizedError {
    case missingAPIKey
    case http(status: Int, body: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add an ElevenLabs API key in Settings → Voice."
        case .http(let status, let body): "ElevenLabs token error (\(status)): \(body.prefix(200))"
        case .malformedResponse: "ElevenLabs returned an unexpected token response."
        }
    }
}

/// Mints a short-lived WebRTC conversation token from the stored API key so the agent can
/// stay private. For a shipping product this call belongs on a server; here it runs locally
/// for a single-user build.
struct ElevenLabsTokenClient {
    var apiKey: String

    private static let base = "https://api.elevenlabs.io/v1/convai/conversation/token"

    func conversationToken(agentId: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ElevenLabsTokenError.missingAPIKey }
        var comps = URLComponents(string: Self.base)!
        comps.queryItems = [URLQueryItem(name: "agent_id", value: agentId)]

        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw ElevenLabsTokenError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty else {
            throw ElevenLabsTokenError.malformedResponse
        }
        return token
    }
}
