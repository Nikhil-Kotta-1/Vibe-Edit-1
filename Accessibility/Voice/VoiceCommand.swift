import Foundation

/// A resolved voice intent for DEFAULT mode. The matcher maps speech to one of
/// these; it never touches the editor. Mode-transition cases (agent/sidebar/help)
/// are interpreted by `VoiceModeController`; the rest are editor actions the
/// dispatcher runs. Seeks are in seconds so this stays frame-rate agnostic.
enum VoiceCommand: Equatable, Sendable {

    // Transport (mouse-only — the agent has no tool for these)
    case play
    case pause
    case togglePlayback

    // Playhead
    case stepFrame(forward: Bool)
    /// Relative move; negative is backward.
    case skip(seconds: Double)
    case jumpToStart
    case jumpToEnd

    // View
    case zoom(in: Bool)

    // Editing
    case select   // select the clip under the playhead
    case split
    case delete
    case undo
    case redo
    case copy
    case paste

    // Discoverability overlay
    case showHelp
    case hideHelp

    // Mode transitions (handled by VoiceModeController)
    case enterAgentMode   // "Spielberg"
    case exitAgentMode    // "thank you Spielberg"
    case enterSleep       // "sleep"
    case exitSleep        // "wake up"

    /// Matched nothing; carries the normalized transcript for the feedback box.
    case unrecognized(String)
}

extension VoiceCommand {
    /// Line shown in the always-on visual feedback box (the app never speaks).
    var feedbackMessage: String {
        switch self {
        case .play: return "Playing"
        case .pause: return "Paused"
        case .togglePlayback: return "Toggled playback"
        case .stepFrame(let fwd): return fwd ? "Forward one frame" : "Back one frame"
        case .skip(let s):
            let n = Int(abs(s).rounded())
            return s < 0 ? "Skipped back \(n)s" : "Skipped forward \(n)s"
        case .jumpToStart: return "At start"
        case .jumpToEnd: return "At end"
        case .zoom(let zin): return zin ? "Zoomed in" : "Zoomed out"
        case .select: return "Selected clip"
        case .split: return "Split"
        case .delete: return "Deleted"
        case .undo: return "Undone"
        case .redo: return "Redone"
        case .copy: return "Copied"
        case .paste: return "Pasted"
        case .showHelp: return "Showing commands"
        case .hideHelp: return "Closed"
        case .enterAgentMode: return "Now listening"
        case .exitAgentMode: return "Sending to Spielberg"
        case .enterSleep: return "Sleeping"
        case .exitSleep: return "Awake"
        case .unrecognized: return ""
        }
    }

    /// True for cases that switch mode rather than act on the editor.
    var isModeTransition: Bool {
        switch self {
        case .enterAgentMode, .exitAgentMode, .enterSleep, .exitSleep: return true
        default: return false
        }
    }
}
