import Foundation
import Observation

/// Drives the voice state machine. It consumes finalized transcripts from a
/// `TranscriptSource`, runs the `CommandMatcher`, applies `VoiceModeReducer`,
/// performs side effects through injected closures, and publishes status for the
/// feedback UI. `@MainActor` because effects ultimately touch the editor and UI.
///
/// It depends only on closures (not on `EditorViewModel` or `VoiceConversationService`)
/// so the whole brain is unit-testable with a mock source.
@MainActor
@Observable
final class VoiceModeController {

    private(set) var mode: VoiceMode = .default
    private(set) var statusMessage: String = VoiceModeController.idleHint
    private(set) var isHelpVisible = false

    static let idleHint = #"No commands running — say "play", "pause", or "help""#
    static let sleepHint = #"Sleeping — say "wake up""#

    @ObservationIgnored private let source: TranscriptSource
    @ObservationIgnored private let matcher: CommandMatcher
    @ObservationIgnored private let onDispatch: @MainActor (VoiceCommand) -> Void
    @ObservationIgnored private let onAgentStart: @MainActor () -> Void
    @ObservationIgnored private let onAgentEnd: @MainActor () -> Void
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        source: TranscriptSource,
        matcher: CommandMatcher = CommandMatcher(),
        onDispatch: @escaping @MainActor (VoiceCommand) -> Void,
        onAgentStart: @escaping @MainActor () -> Void = {},
        onAgentEnd: @escaping @MainActor () -> Void = {}
    ) {
        self.source = source
        self.matcher = matcher
        self.onDispatch = onDispatch
        self.onAgentStart = onAgentStart
        self.onAgentEnd = onAgentEnd
    }

    /// Begin listening: start the source and drain its stream.
    func start() async throws {
        try await source.start()
        task = Task { [weak self] in
            guard let self else { return }
            for await phrase in self.source.transcripts {
                self.process(phrase)
            }
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
        await source.stop()
    }

    /// Handle one finalized utterance (also the test entry point).
    func process(_ transcript: String) {
        let command = matcher.match(transcript)
        voiceLog("🎙️VOICE controller transcript=\"\(transcript)\" → \(command) [mode=\(mode)]")
        apply(command)
    }

    /// Apply a resolved command through the reducer and perform its effect.
    func apply(_ command: VoiceCommand) {
        let (next, effect) = VoiceModeReducer.reduce(mode: mode, command: command)
        mode = next
        switch effect {
        case .none:
            setStatus(command)
        case .dispatch(let editorCommand):
            onDispatch(editorCommand)
            setStatus(editorCommand)
        case .startAgent:
            onAgentStart()
            setStatus(command)
        case .endAgent:
            onAgentEnd()
            setStatus(command)
        case .showHelp:
            isHelpVisible = true
            setStatus(command)
        case .hideHelp:
            isHelpVisible = false
            setStatus(command)
        case .ignored:
            break  // keep current status; mode suppressed the command
        }
    }

    private func setStatus(_ command: VoiceCommand) {
        let message = command.feedbackMessage
        statusMessage = message.isEmpty
            ? (mode == .sleep ? Self.sleepHint : Self.idleHint)
            : message
    }
}
