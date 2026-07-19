import Foundation

/// The editor operations a voice command can trigger. The dispatcher depends on
/// this protocol, not on `EditorViewModel`, so it unit-tests with a mock and the
/// real adapter lives in one small extension.
@MainActor
protocol VoiceEditorTarget: AnyObject {
    func play()
    func pause()
    func togglePlayback()
    func stepFrame(forward: Bool)
    func skip(seconds: Double)
    func jumpToStart()
    func jumpToEnd()
    func zoom(in zoomIn: Bool)
    func selectAtPlayhead()
    func split()
    func delete()
    func undo()
    func redo()
    func copyClips()
    func pasteClips()
}

/// Maps a resolved `VoiceCommand` to a `VoiceEditorTarget` call. Mode-transition,
/// help, and unrecognized cases are no-ops here — those never reach the editor;
/// `VoiceModeController` consumes them as effects.
@MainActor
struct VoiceCommandDispatcher {
    private let target: VoiceEditorTarget

    init(target: VoiceEditorTarget) {
        self.target = target
    }

    func dispatch(_ command: VoiceCommand) {
        switch command {
        case .play:                 target.play()
        case .pause:                target.pause()
        case .togglePlayback:       target.togglePlayback()
        case .stepFrame(let fwd):   target.stepFrame(forward: fwd)
        case .skip(let seconds):    target.skip(seconds: seconds)
        case .jumpToStart:          target.jumpToStart()
        case .jumpToEnd:            target.jumpToEnd()
        case .zoom(let zoomIn):     target.zoom(in: zoomIn)
        case .select:               target.selectAtPlayhead()
        case .split:                target.split()
        case .delete:               target.delete()
        case .undo:                 target.undo()
        case .redo:                 target.redo()
        case .copy:                 target.copyClips()
        case .paste:                target.pasteClips()
        case .showHelp, .hideHelp,
             .enterAgentMode, .exitAgentMode,
             .enterSleep, .exitSleep,
             .unrecognized:
            break  // not editor actions — handled by VoiceModeController
        }
    }
}
