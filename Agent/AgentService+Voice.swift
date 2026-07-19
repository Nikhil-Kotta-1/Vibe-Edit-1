import Foundation

extension AgentService {

    /// Routes a spoken request through the existing agent loop and returns the concise
    /// terminal assistant text for the voice agent to speak. Never throws — failures come
    /// back as a short spoken phrase. Shares the chat transcript, so spoken edits appear
    /// in the panel like typed ones.
    func runVoiceRequest(_ text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "I didn't catch that — say it again?" }
        guard canStream else {
            return "You'll need to sign in to a paid plan or add an Anthropic API key first."
        }

        editor?.agentPanelVisible = true
        messages.append(AgentMessage(role: .user, blocks: [.text(trimmed)]))
        streamError = nil

        await runAgentTurn().value

        if let err = streamError {
            return Self.voicePhrase(for: err)
        }
        return Self.terminalAssistantText(in: messages) ?? "Done."
    }

    /// One-breath natural-language summary of the current timeline, for the voice agent's
    /// opening context and the `describe_timeline` tool.
    func voiceContextSummary() -> String {
        guard let editor else { return "No project is open right now." }
        let tl = editor.timeline
        let clipCount = tl.tracks.reduce(0) { $0 + $1.clips.count }
        guard clipCount > 0 else {
            return "The timeline is empty — \(tl.width)×\(tl.height) at \(tl.fps) fps, " +
                "with \(editor.mediaAssets.count) assets in the library."
        }
        let seconds = tl.fps > 0 ? Double(tl.totalFrames) / Double(tl.fps) : 0
        let visualTracks = tl.tracks.filter { $0.type.isVisual }.count
        let audioTracks = tl.tracks.filter { $0.type == .audio }.count
        return "Timeline: \(tl.width)×\(tl.height) at \(tl.fps) fps, " +
            "\(Self.spokenDuration(seconds)) long. " +
            "\(tl.tracks.count) tracks (\(visualTracks) visual, \(audioTracks) audio), " +
            "\(clipCount) clips. \(editor.mediaAssets.count) assets in the library."
    }

    private static func spokenDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) seconds" }
        let m = total / 60, s = total % 60
        return s == 0 ? "\(m) minutes" : "\(m) minutes \(s) seconds"
    }

    private static func terminalAssistantText(in messages: [AgentMessage]) -> String? {
        guard let last = messages.last(where: { $0.role == .assistant }) else { return nil }
        let text = last.blocks.compactMap { block -> String? in
            if case let .text(s) = block { return s }
            return nil
        }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func voicePhrase(for error: VibeEditClientError) -> String {
        switch error {
        case .unauthenticated: return "You'll need to sign in to use the agent."
        case .insufficientCredits: return "You're out of credits for that."
        case .upstream(let m): return "That didn't go through: \(m)"
        }
    }
}
