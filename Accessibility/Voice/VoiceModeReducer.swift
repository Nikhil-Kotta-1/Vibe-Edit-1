import Foundation

/// The three exclusive listening modes.
enum VoiceMode: Sendable, Equatable {
    case `default`   // local commands run; mic is a remote control
    case agent       // Spielberg bracket: speech goes to ElevenLabs/agent
    case sleep       // everything ignored except "wake up"
}

/// What a command does in the current mode. Pure data so the state machine is
/// testable without touching the editor, mic, or ElevenLabs.
enum VoiceEffect: Equatable, Sendable {
    case none                    // mode changed / idle, no editor side effect
    case dispatch(VoiceCommand)  // run an editor action
    case startAgent              // open the ElevenLabs bracket
    case endAgent                // close it and submit
    case showHelp
    case hideHelp
    case ignored                 // command suppressed by the current mode
}

/// Pure transition function for the voice state machine.
enum VoiceModeReducer {
    static func reduce(mode: VoiceMode, command: VoiceCommand) -> (mode: VoiceMode, effect: VoiceEffect) {
        switch mode {
        case .sleep:
            // Only a wake word gets through; the mic is otherwise muted.
            return command == .exitSleep ? (.default, .none) : (.sleep, .ignored)

        case .agent:
            // ElevenLabs owns the conversation; we only watch for the closer.
            return command == .exitAgentMode ? (.default, .endAgent) : (.agent, .ignored)

        case .default:
            switch command {
            case .enterAgentMode:            return (.agent, .startAgent)
            case .enterSleep:                return (.sleep, .none)
            case .showHelp:                  return (.default, .showHelp)
            case .hideHelp:                  return (.default, .hideHelp)
            case .exitAgentMode, .exitSleep: return (.default, .ignored)  // not in that mode
            case .unrecognized:              return (.default, .none)
            default:                         return (.default, .dispatch(command))
            }
        }
    }
}
