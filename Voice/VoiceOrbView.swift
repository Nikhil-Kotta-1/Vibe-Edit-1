import SwiftUI

/// Live state + controls for an active voice conversation. Pure phase-driven; no app state.
struct VoiceOrbView: View {
    let phase: VoiceConversationService.Phase
    let isMuted: Bool
    let onMute: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            indicator
                .font(.system(size: AppTheme.FontSize.md))
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)

            Text(statusText)
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(AppTheme.Text.secondaryColor))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if showsControls {
                controlButton(systemName: isMuted ? "mic.slash.fill" : "mic.fill",
                              help: isMuted ? "Unmute" : "Mute", action: onMute)
                controlButton(systemName: "stop.fill", help: "End conversation", action: onEnd)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .glassEffect(.regular, in: .rect(cornerRadius: AppTheme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
        .animation(.easeOut(duration: AppTheme.Anim.transition), value: statusText)
    }

    @ViewBuilder
    private var indicator: some View {
        switch phase {
        case .connecting, .thinking:
            ThinkingDots()
        case .listening:
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative)
                .foregroundStyle(AppTheme.Accent.primary)
        case .speaking:
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative)
                .foregroundStyle(AppTheme.aiGradient)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }

    private func controlButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
    }

    private var isError: Bool {
        if case .error = phase { return true }
        return false
    }

    private var showsControls: Bool {
        switch phase {
        case .connecting, .listening, .thinking, .speaking: return true
        case .idle, .error: return false
        }
    }

    private var statusText: String {
        switch phase {
        case .idle: return ""
        case .connecting: return "Connecting…"
        case .listening: return "Listening…"
        case .thinking: return "Working…"
        case .speaking: return "Speaking…"
        case .error(let message): return message
        }
    }
}

/// Drops the live voice strip into the agent panel footer when a session is running.
struct VoiceFooterStrip: View {
    @Bindable private var appState = AppState.shared

    var body: some View {
        if let voice = appState.voiceService, voice.phase != .idle {
            VoiceOrbView(
                phase: voice.phase,
                isMuted: voice.isMuted,
                onMute: { Task { await voice.toggleMute() } },
                onEnd: { Task { await voice.stop() } }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
