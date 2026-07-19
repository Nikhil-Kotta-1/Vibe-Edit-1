import Testing
@testable import VibeEdit

/// Records calls so we can assert the command -> editor-op mapping without a
/// real timeline.
@MainActor
final class RecordingEditorTarget: VoiceEditorTarget {
    var calls: [String] = []
    func play() { calls.append("play") }
    func pause() { calls.append("pause") }
    func togglePlayback() { calls.append("toggle") }
    func stepFrame(forward: Bool) { calls.append("step:\(forward)") }
    func skip(seconds: Double) { calls.append("skip:\(seconds)") }
    func jumpToStart() { calls.append("start") }
    func jumpToEnd() { calls.append("end") }
    func zoom(in zoomIn: Bool) { calls.append("zoom:\(zoomIn)") }
    func selectAtPlayhead() { calls.append("select") }
    func split() { calls.append("split") }
    func delete() { calls.append("delete") }
    func undo() { calls.append("undo") }
    func redo() { calls.append("redo") }
    func copyClips() { calls.append("copy") }
    func pasteClips() { calls.append("paste") }
}

@MainActor
@Suite("VoiceCommandDispatcher")
struct VoiceCommandDispatcherTests {

    @Test func mapsEditorCommandsToTargetCalls() {
        let target = RecordingEditorTarget()
        let dispatcher = VoiceCommandDispatcher(target: target)

        for command in [VoiceCommand.play, .pause, .togglePlayback,
                        .stepFrame(forward: true), .stepFrame(forward: false),
                        .skip(seconds: 5), .skip(seconds: -10),
                        .jumpToStart, .jumpToEnd, .zoom(in: true), .zoom(in: false),
                        .select, .split, .delete, .undo, .redo, .copy, .paste] {
            dispatcher.dispatch(command)
        }

        #expect(target.calls == [
            "play", "pause", "toggle",
            "step:true", "step:false",
            "skip:5.0", "skip:-10.0",
            "start", "end", "zoom:true", "zoom:false",
            "select", "split", "delete", "undo", "redo", "copy", "paste",
        ])
    }

    @Test func nonEditorCommandsAreNoOps() {
        let target = RecordingEditorTarget()
        let dispatcher = VoiceCommandDispatcher(target: target)
        for command in [VoiceCommand.showHelp, .hideHelp, .enterAgentMode,
                        .exitAgentMode, .enterSleep, .exitSleep, .unrecognized("x")] {
            dispatcher.dispatch(command)
        }
        #expect(target.calls.isEmpty)
    }
}
