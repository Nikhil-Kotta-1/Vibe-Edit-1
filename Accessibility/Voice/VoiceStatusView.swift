import SwiftUI

/// Always-on feedback box for voice control: a colored mode light plus the last
/// action ("Playing", "Sleeping", "Now listening"). Shows the command list when
/// "help" is spoken. Floats at the top of the preview while voice mode is on.
struct VoiceStatusView: View {
    private let coordinator = VoiceControlCoordinator.shared
    private var controller: VoiceModeController { coordinator.controller }

    var body: some View {
        if coordinator.isEnabled {
            VStack(spacing: AppTheme.Spacing.sm) {
                statusCapsule
                if controller.isHelpVisible {
                    helpCard
                }
            }
            .padding(.top, AppTheme.Spacing.smMd)
            .animation(.easeOut(duration: AppTheme.Anim.transition), value: controller.isHelpVisible)
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: message)
        }
    }

    // MARK: - Status capsule

    private var statusCapsule: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Circle()
                .fill(modeColor)
                .frame(width: AppTheme.IconSize.xxs, height: AppTheme.IconSize.xxs)
                .shadow(color: modeColor.opacity(AppTheme.Opacity.strong), radius: 4)
            Text(message)
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Background.raisedColor, in: Capsule())
        .overlay(Capsule().strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin))
        .shadow(AppTheme.Shadow.md)
    }

    private var message: String {
        coordinator.errorMessage ?? controller.statusMessage
    }

    private var modeColor: Color {
        if coordinator.errorMessage != nil { return AppTheme.Status.errorColor }
        switch controller.mode {
        case .default: return AppTheme.Accent.primary
        case .agent:   return AppTheme.Accent.spotlight
        case .sleep:   return AppTheme.Text.mutedColor
        }
    }

    // MARK: - Help card

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            ForEach(Self.helpGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(group.title.uppercased())
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text(group.commands)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            Text(#"Say "close" to dismiss"#)
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(maxWidth: 320, alignment: .leading)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        )
        .shadow(AppTheme.Shadow.lg)
    }

    private struct HelpGroup { let title: String; let commands: String }

    private static let helpGroups: [HelpGroup] = [
        HelpGroup(title: "Playback", commands: #"play · pause · next/previous frame · "skip forward 10 seconds" · go to start/end"#),
        HelpGroup(title: "Editing", commands: "select · split · delete · undo · redo · copy · paste · zoom in/out"),
        HelpGroup(title: "Modes", commands: #""sleep" to pause listening · "wake up" to resume"#),
    ]
}
