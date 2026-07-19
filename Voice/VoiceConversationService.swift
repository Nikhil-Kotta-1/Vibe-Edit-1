import AVFoundation
import Combine
import ElevenLabs
import Foundation
import Observation

/// Live voice conversation. ElevenLabs runs the speech loop (STT, turn-taking, barge-in, TTS)
/// and calls the `edit_timeline` / `describe_timeline` client tools, which bridge into the
/// existing in-app agent. One instance app-wide; it resolves the active editor on each call.
@Observable
@MainActor
final class VoiceConversationService {

    enum Phase: Equatable {
        case idle, connecting, listening, thinking, speaking
        case error(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var isActive = false
    private(set) var isMuted = false

    @ObservationIgnored private let editorProvider: () -> EditorViewModel?
    @ObservationIgnored private var conversation: Conversation?
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var handledToolCalls: Set<String> = []
    @ObservationIgnored private var isRunningEdit = false
    @ObservationIgnored private var lastState: ConversationState = .idle
    @ObservationIgnored private var lastAgentState: ElevenLabs.AgentState = .listening
    @ObservationIgnored private var lastSDKError: String?

    init(editorProvider: @escaping () -> EditorViewModel?) {
        self.editorProvider = editorProvider
    }

    private var editor: EditorViewModel? { editorProvider() }

    // MARK: - Lifecycle

    func start() async {
        guard !isActive, phase != .connecting else { return }
        await teardownSession()
        guard await ensureMicPermission() else { return }
        guard let agentId = ElevenLabsKeychain.loadAgentId(), !agentId.isEmpty else {
            phase = .error("Add an ElevenLabs Agent ID in Settings → Voice.")
            return
        }

        phase = .connecting
        let summary = editor?.agentService.voiceContextSummary() ?? "No project is open."
        let apiKey = ElevenLabsKeychain.loadAPIKey()

        // Try direct first (lowest latency); if the room connection fails — usually macOS Local
        // Network permission or a restrictive/UDP-blocking network — retry forcing TURN relay,
        // which needs neither local-network access nor open UDP.
        var lastError = "Connection failed."
        for strategy in [LiveKitNetworkConfiguration.Strategy.automatic, .relayOnly] {
            lastSDKError = nil
            do {
                let convo = try await connect(agentId: agentId, apiKey: apiKey, summary: summary, strategy: strategy)
                conversation = convo
                isActive = true
                observe(convo)
                return
            } catch is CancellationError {
                return
            } catch {
                lastError = lastSDKError ?? error.localizedDescription
            }
        }
        phase = .error(Self.connectionMessage(lastError))
        isActive = false
        conversation = nil
    }

    private func connect(
        agentId: String,
        apiKey: String?,
        summary: String,
        strategy: LiveKitNetworkConfiguration.Strategy
    ) async throws -> Conversation {
        // The SDK reports the precise cause (e.g. localNetworkPermissionRequired) via onError,
        // separately from the generic error it throws — capture it for an actionable message.
        let config = ConversationConfig(
            dynamicVariables: ["timeline_summary": summary],
            networkConfiguration: LiveKitNetworkConfiguration(strategy: strategy),
            onError: { [weak self] err in
                MainActor.assumeIsolated { self?.lastSDKError = err.errorDescription }
            }
        )
        if let apiKey, !apiKey.isEmpty {
            let token = try await ElevenLabsTokenClient(apiKey: apiKey).conversationToken(agentId: agentId)
            return try await ElevenLabs.startConversation(conversationToken: token, config: config)
        }
        return try await ElevenLabs.startConversation(agentId: agentId, config: config)
    }

    private static func connectionMessage(_ detail: String) -> String {
        let lower = detail.lowercased()
        if lower.contains("local network") {
            return "Local Network permission needed: enable VibeEdit in System Settings → Privacy & Security → Local Network, then try again."
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "Connection timed out. Check Local Network permission and any firewall/VPN, or try another network, then retry."
        }
        return detail
    }

    func stop() async {
        await teardownSession()
        isActive = false
        lastState = .idle
        lastAgentState = .listening
        phase = .idle
    }

    /// Cancels observers and ends any live conversation. Safe to call when idle.
    private func teardownSession() async {
        observers.forEach { $0.cancel() }
        observers.removeAll()
        handledToolCalls.removeAll()
        isRunningEdit = false
        if let convo = conversation { await convo.endConversation() }
        conversation = nil
    }

    func toggle() async {
        if isActive { await stop() } else { await start() }
    }

    func toggleMute() async {
        guard let convo = conversation else { return }
        try? await convo.toggleMute()
    }

    // MARK: - Observation

    private func observe(_ convo: Conversation) {
        observers.append(Task { [weak self] in
            for await state in convo.$state.values {
                guard let self else { return }
                self.lastState = state
                if case .ended = state { self.isActive = false }
                if case .error = state { self.isActive = false }
                self.recomputePhase()
            }
        })
        observers.append(Task { [weak self] in
            for await agentState in convo.$agentState.values {
                self?.lastAgentState = agentState
                self?.recomputePhase()
            }
        })
        observers.append(Task { [weak self] in
            for await muted in convo.$isMuted.values { self?.isMuted = muted }
        })
        observers.append(Task { [weak self] in
            for await calls in convo.$pendingToolCalls.values {
                guard let self else { return }
                for call in calls where !self.handledToolCalls.contains(call.toolCallId) {
                    self.handledToolCalls.insert(call.toolCallId)
                    await self.handleToolCall(call, on: convo)
                }
            }
        })
    }

    private func recomputePhase() {
        switch lastState {
        case .idle: phase = .idle
        case .connecting: phase = .connecting
        case .ended: phase = .idle
        case .error(let err): phase = .error(err.localizedDescription)
        case .active:
            if isRunningEdit { phase = .thinking; return }
            switch lastAgentState {
            case .listening: phase = .listening
            case .speaking: phase = .speaking
            case .thinking: phase = .thinking
            }
        }
    }

    // MARK: - Tool bridge

    private func handleToolCall(_ call: ClientToolCallEvent, on convo: Conversation) async {
        let params = (try? call.getParameters()) ?? [:]
        let resultText: String

        switch call.toolName {
        case "edit_timeline":
            let request = (params["request"] as? String) ?? ""
            if let service = editor?.agentService {
                isRunningEdit = true
                recomputePhase()
                resultText = await service.runVoiceRequest(request)
                isRunningEdit = false
                recomputePhase()
            } else {
                resultText = "No project is open right now."
            }
        case "describe_timeline":
            resultText = editor?.agentService.voiceContextSummary() ?? "No project is open right now."
        default:
            resultText = "Unknown tool: \(call.toolName)"
        }

        try? await convo.sendToolResult(for: call.toolCallId, result: resultText)
    }

    // MARK: - Microphone

    private func ensureMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { phase = .error("Microphone access denied.") }
            return granted
        case .denied, .restricted:
            phase = .error("Enable microphone access in System Settings → Privacy.")
            return false
        @unknown default:
            return false
        }
    }
}
