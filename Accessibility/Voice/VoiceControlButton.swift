import SwiftUI

/// Toggles hands-free voice command mode on/off. Sits beside `VoiceCallButton`
/// in the agent footer.
struct VoiceControlButton: View {
    private let coordinator = VoiceControlCoordinator.shared

    var body: some View {
        Button(action: { Task { await coordinator.toggle() } }) {
            Image(systemName: coordinator.isEnabled ? "ear.fill" : "ear")
                .font(.system(size: AppTheme.FontSize.lg))
                .foregroundStyle(tint)
                .opacity(coordinator.isEnabled ? AppTheme.Opacity.opaque : AppTheme.Opacity.strong)
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var tint: AnyShapeStyle {
        if coordinator.errorMessage != nil { return AnyShapeStyle(AppTheme.Status.errorColor) }
        return coordinator.isEnabled
            ? AnyShapeStyle(AppTheme.Accent.primary)
            : AnyShapeStyle(AppTheme.aiGradient)
    }

    private var helpText: String {
        if let error = coordinator.errorMessage { return error }
        return coordinator.isEnabled ? "Turn off voice commands" : "Turn on voice commands"
    }
}
