import SwiftUI

/// Toggles ElevenLabs voice dictation: speak a prompt, it's transcribed and sent to the agent
/// chat, then it keeps listening for the next one. Sits beside the Apple command ear in the agent
/// input bar; the two are mutually exclusive (enabling one stops the other).
struct VoiceCallButton: View {
    private let dictation = ElevenLabsDictationService.shared

    private var isActive: Bool { dictation.isActive }
    private var phase: ElevenLabsDictationService.Phase { dictation.phase }

    var body: some View {
        Button(action: { Task { await dictation.toggle() } }) {
            Image(systemName: isActive ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: AppTheme.FontSize.lg))
                .foregroundStyle(tint)
                .opacity(isActive ? AppTheme.Opacity.opaque : AppTheme.Opacity.strong)
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                .symbolEffect(.variableColor.iterative, isActive: isAnimating)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var tint: AnyShapeStyle {
        if case .error = phase { return AnyShapeStyle(AppTheme.Status.errorColor) }
        return isActive ? AnyShapeStyle(AppTheme.Accent.primary) : AnyShapeStyle(AppTheme.aiGradient)
    }

    private var isAnimating: Bool {
        switch phase {
        case .listening, .transcribing: return true
        case .idle, .error: return false
        }
    }

    private var helpText: String {
        switch phase {
        case .idle: return "Dictate to the agent with ElevenLabs"
        case .listening: return "Listening — speak a prompt (tap to stop)"
        case .transcribing: return "Transcribing…"
        case .error(let message): return message
        }
    }
}
