import Foundation

enum ElevenLabsSTTError: LocalizedError {
    case missingAPIKey
    case http(status: Int, body: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add an ElevenLabs API key in Settings → Voice."
        case .http(let status, let body): "ElevenLabs transcription error (\(status)): \(body.prefix(160))"
        case .malformedResponse: "ElevenLabs returned an unexpected transcription response."
        }
    }
}

/// Transcribes an audio file via ElevenLabs Scribe speech-to-text. Pure transcription — no
/// agent, no TTS — so it drives the dictation toggle that turns spoken prompts into chat text.
/// Like `ElevenLabsTokenClient`, this calls the API directly for a single-user local build.
struct ElevenLabsSTTClient {
    var apiKey: String
    var modelId: String = "scribe_v1"

    private static let endpoint = "https://api.elevenlabs.io/v1/speech-to-text"

    func transcribe(fileURL: URL, contentType: String = "audio/wav") async throws -> String {
        guard !apiKey.isEmpty else { throw ElevenLabsSTTError.missingAPIKey }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: Self.endpoint)!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        let audio = try Data(contentsOf: fileURL)
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n\(modelId)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw ElevenLabsSTTError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw ElevenLabsSTTError.malformedResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
