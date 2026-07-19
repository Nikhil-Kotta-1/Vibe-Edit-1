import AppKit
import Foundation

/// Top-level glue for hands-free voice control. Owns the on-device Apple speech source and the
/// mode controller, and runs the finite set of local editor commands (play, pause, navigate,
/// zoom, split, undo…) entirely on-device.
///
/// It deliberately does **not** touch ElevenLabs. Natural-language "vibe editing" lives on a
/// separate dictation toggle (`ElevenLabsDictationService`), and the two are mutually exclusive:
/// enabling one disables the other, so the microphone always has exactly one owner.
///
/// Each `enable()` builds a **fresh** speech source + controller. The transcript stream is
/// single-use (its `AsyncStream` is finished on `stop()` and can't be revived), so a clean
/// session every time guarantees re-enabling always starts from the default state.
@MainActor
@Observable
final class VoiceControlCoordinator {

    static let shared = VoiceControlCoordinator(
        editorProvider: { AppState.shared.activeProject?.editorViewModel }
    )

    private(set) var isEnabled = false
    private(set) var errorMessage: String?

    /// Exposed so the feedback UI can observe mode / status / help visibility. Swapped for a
    /// fresh instance on each enable.
    private(set) var controller: VoiceModeController

    @ObservationIgnored private let editorProvider: () -> EditorViewModel?
    @ObservationIgnored private var speech: AppleSpeechTranscriptSource

    init(editorProvider: @escaping () -> EditorViewModel?) {
        self.editorProvider = editorProvider
        let session = Self.makeSession(editorProvider: editorProvider)
        self.speech = session.0
        self.controller = session.1
    }

    private static func makeSession(
        editorProvider: @escaping () -> EditorViewModel?
    ) -> (AppleSpeechTranscriptSource, VoiceModeController) {
        let matcher = CommandMatcher()
        let speech = AppleSpeechTranscriptSource(contextualStrings: matcher.contextualVocabulary)
        let controller = VoiceModeController(
            source: speech,
            matcher: matcher,
            onDispatch: { command in
                guard let editor = editorProvider() else { return }
                VoiceCommandDispatcher(target: editor).dispatch(command)
            }
        )
        return (speech, controller)
    }

    func toggle() async {
        isEnabled ? await disable() : await enable()
    }

    func enable() async {
        guard !isEnabled else { return }
        ElevenLabsDictationService.shared.stop()   // never share the mic with dictation
        // Fresh session every time → always a clean default start.
        (speech, controller) = Self.makeSession(editorProvider: editorProvider)
        do {
            try await controller.start()
            isEnabled = true
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isEnabled = false
        }
    }

    func disable() async {
        guard isEnabled else { return }
        isEnabled = false
        await controller.stop()
    }
}
