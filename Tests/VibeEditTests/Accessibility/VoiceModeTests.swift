import Testing
@testable import VibeEdit

@Suite("VoiceModeReducer")
struct VoiceModeReducerTests {

    @Test func defaultModeRunsCommands() {
        let r = VoiceModeReducer.reduce(mode: .default, command: .play)
        #expect(r.mode == .default)
        #expect(r.effect == .dispatch(.play))
    }

    @Test func defaultModeEntersAgentAndSleep() {
        #expect(VoiceModeReducer.reduce(mode: .default, command: .enterAgentMode).effect == .startAgent)
        #expect(VoiceModeReducer.reduce(mode: .default, command: .enterAgentMode).mode == .agent)
        #expect(VoiceModeReducer.reduce(mode: .default, command: .enterSleep).mode == .sleep)
    }

    @Test func agentModeSuppressesEverythingButTheCloser() {
        #expect(VoiceModeReducer.reduce(mode: .agent, command: .play).effect == .ignored)
        #expect(VoiceModeReducer.reduce(mode: .agent, command: .split).effect == .ignored)
        let close = VoiceModeReducer.reduce(mode: .agent, command: .exitAgentMode)
        #expect(close.mode == .default)
        #expect(close.effect == .endAgent)
    }

    @Test func sleepModeSuppressesEverythingButWake() {
        #expect(VoiceModeReducer.reduce(mode: .sleep, command: .play).effect == .ignored)
        #expect(VoiceModeReducer.reduce(mode: .sleep, command: .enterAgentMode).effect == .ignored)
        #expect(VoiceModeReducer.reduce(mode: .sleep, command: .exitSleep).mode == .default)
    }

    @Test func helpTogglesWithoutLeavingDefault() {
        #expect(VoiceModeReducer.reduce(mode: .default, command: .showHelp).effect == .showHelp)
        #expect(VoiceModeReducer.reduce(mode: .default, command: .hideHelp).effect == .hideHelp)
    }
}

@MainActor
@Suite("VoiceModeController")
struct VoiceModeControllerTests {

    @Test func suppressesCommandsInSleepMode() {
        var dispatched: [VoiceCommand] = []
        let controller = VoiceModeController(
            source: MockTranscriptSource(),
            onDispatch: { dispatched.append($0) }
        )

        for phrase in ["play", "sleep", "play", "wake up", "play", "zoom in"] {
            controller.process(phrase)
        }

        #expect(dispatched == [.play, .play, .zoom(in: true)])
        #expect(controller.mode == .default)
    }

    @Test func statusReflectsLastAction() {
        let controller = VoiceModeController(source: MockTranscriptSource(), onDispatch: { _ in })
        controller.apply(.play)
        #expect(controller.statusMessage == "Playing")
        controller.apply(.enterSleep)
        #expect(controller.statusMessage == "Sleeping")
        controller.apply(.play)  // suppressed in sleep -> status unchanged
        #expect(controller.statusMessage == "Sleeping")
    }
}
