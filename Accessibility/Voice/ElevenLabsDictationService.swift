import AVFoundation
import Foundation
import Observation

/// Continuous voice dictation powered by ElevenLabs Scribe. Toggle it on and it records, and each
/// time you pause it transcribes what you said and drops it into the agent chat as a sent message —
/// then keeps listening for the next prompt. Toggle it off (or switch on the Apple ear) to stop.
///
/// Mutually exclusive with `VoiceControlCoordinator` (the Apple command recognizer): starting one
/// stops the other, so the microphone always has exactly one owner.
@MainActor
@Observable
final class ElevenLabsDictationService {

    enum Phase: Equatable { case idle, listening, transcribing, error(String) }

    static let shared = ElevenLabsDictationService(
        editorProvider: { AppState.shared.activeProject?.editorViewModel }
    )

    private(set) var phase: Phase = .idle
    private(set) var isActive = false

    @ObservationIgnored private let editorProvider: () -> EditorViewModel?
    @ObservationIgnored private var capture: DictationAudioCapture?
    @ObservationIgnored private var drain: Task<Void, Never>?
    @ObservationIgnored private var cachedAPIKey: String?

    init(editorProvider: @escaping () -> EditorViewModel?) {
        self.editorProvider = editorProvider
    }

    func toggle() async { isActive ? stop() : await start() }

    func start() async {
        guard !isActive else { return }
        await VoiceControlCoordinator.shared.disable()   // never share the mic with Apple recognition

        guard let key = apiKey() else {
            phase = .error("Add an ElevenLabs API key in Settings → Voice."); return
        }
        guard await ensureMicPermission() else {
            phase = .error("Enable microphone access in System Settings → Privacy."); return
        }

        let capture = DictationAudioCapture()
        do {
            try capture.start()
        } catch {
            phase = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return
        }
        self.capture = capture
        isActive = true
        phase = .listening

        let client = ElevenLabsSTTClient(apiKey: key)
        drain = Task { [weak self] in
            for await url in capture.utterances {
                await self?.handle(url, client: client)
            }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        drain?.cancel(); drain = nil
        capture?.stop(); capture = nil
        phase = .idle
    }

    private func handle(_ url: URL, client: ElevenLabsSTTClient) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard isActive else { return }
        phase = .transcribing
        do {
            let text = try await client.transcribe(fileURL: url)
            guard isActive else { return }
            phase = .listening
            guard !text.isEmpty else { return }
            voiceLog("🎙️DICTATION → agent: \(text)")
            editorProvider()?.agentService.send(text: text, mentions: [])
        } catch {
            voiceLog("🎙️DICTATION transcribe error: \(error.localizedDescription)")
            if isActive { phase = .listening }   // keep the session alive
        }
    }

    /// Reads the key from the keychain once, then reuses it for the rest of the session. Ad-hoc
    /// signed dev builds otherwise re-prompt for the keychain password on every read.
    private func apiKey() -> String? {
        if let cachedAPIKey, !cachedAPIKey.isEmpty { return cachedAPIKey }
        guard let key = ElevenLabsKeychain.loadAPIKey(), !key.isEmpty else { return nil }
        cachedAPIKey = key
        return key
    }

    private func ensureMicPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
