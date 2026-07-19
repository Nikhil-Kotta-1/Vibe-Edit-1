import AVFoundation
import AppKit
import SwiftUI

struct VoicePane: View {
    @State private var hasKey = false
    @State private var maskedKey = ""
    @State private var keyDraft = ""
    @State private var agentId = ""
    @State private var agentDraft = ""
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @FocusState private var keyFocused: Bool
    @FocusState private var agentFocused: Bool

    private let consoleURL = URL(string: "https://elevenlabs.io/app/settings/api-keys")!
    private let agentsURL = URL(string: "https://elevenlabs.io/app/agents")!

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            apiKeySection
            Divider().overlay(AppTheme.Border.subtleColor)
            agentSection
            Divider().overlay(AppTheme.Border.subtleColor)
            microphoneSection
        }
        .onAppear(perform: refresh)
    }

    // MARK: API key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            sectionHeader(
                title: "ElevenLabs API Key",
                detail: "Used to start the voice conversation. Stored in your macOS Keychain.",
                linkTitle: "Get API key",
                url: consoleURL
            )
            HStack(spacing: AppTheme.Spacing.sm) {
                SecureField(hasKey ? maskedKey : "sk_…", text: $keyDraft)
                    .textFieldStyle(.plain)
                    .focused($keyFocused)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .onSubmit(saveKey)
                    .modifier(FieldBox(focused: keyFocused))
                trailingControl(
                    hasValue: !keyDraft.trimmingCharacters(in: .whitespaces).isEmpty,
                    hasStored: hasKey,
                    save: saveKey,
                    remove: removeKey,
                    removeHelp: "Remove API key"
                )
            }
        }
    }

    // MARK: Agent

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            sectionHeader(
                title: "Agent ID",
                detail: "Create the voice agent with scripts/setup-elevenlabs-agent.sh, then paste its ID here.",
                linkTitle: "Open agents",
                url: agentsURL
            )
            HStack(spacing: AppTheme.Spacing.sm) {
                TextField(agentId.isEmpty ? "agent_…" : agentId, text: $agentDraft)
                    .textFieldStyle(.plain)
                    .focused($agentFocused)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .onSubmit(saveAgent)
                    .modifier(FieldBox(focused: agentFocused))
                trailingControl(
                    hasValue: !agentDraft.trimmingCharacters(in: .whitespaces).isEmpty,
                    hasStored: !agentId.isEmpty,
                    save: saveAgent,
                    remove: removeAgent,
                    removeHelp: "Remove agent ID"
                )
            }
        }
    }

    // MARK: Microphone

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text("Microphone")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            HStack(spacing: AppTheme.Spacing.sm) {
                Circle()
                    .fill(micColor)
                    .frame(width: 8, height: 8)
                Text(micLabel)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer()
                micAction
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.black.opacity(AppTheme.Opacity.muted))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            )
        }
    }

    @ViewBuilder
    private var micAction: some View {
        switch micStatus {
        case .notDetermined:
            Button("Grant") {
                Task {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                    micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                }
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.small)
        case .denied, .restricted:
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private var micColor: Color {
        switch micStatus {
        case .authorized: return .green
        case .denied, .restricted: return .red
        default: return AppTheme.Text.mutedColor
        }
    }

    private var micLabel: String {
        switch micStatus {
        case .authorized: return "Granted"
        case .denied, .restricted: return "Denied"
        case .notDetermined: return "Not requested yet"
        @unknown default: return "Unknown"
        }
    }

    // MARK: Shared chrome

    private func sectionHeader(title: String, detail: String, linkTitle: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(detail)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: { NSWorkspace.shared.open(url) }) {
                    HStack(spacing: 2) {
                        Text(linkTitle)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.primary)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func trailingControl(
        hasValue: Bool,
        hasStored: Bool,
        save: @escaping () -> Void,
        remove: @escaping () -> Void,
        removeHelp: String
    ) -> some View {
        if hasValue {
            Button("Save", action: save)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasStored {
            Button(action: remove) {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .help(removeHelp)
        }
    }

    // MARK: Actions

    private func refresh() {
        let key = ElevenLabsKeychain.loadAPIKey() ?? ""
        hasKey = !key.isEmpty
        maskedKey = mask(key)
        agentId = ElevenLabsKeychain.loadAgentId() ?? ""
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        ElevenLabsKeychain.saveAPIKey(key)
        keyDraft = ""
        keyFocused = false
        refresh()
    }

    private func removeKey() {
        ElevenLabsKeychain.deleteAPIKey()
        keyDraft = ""
        refresh()
    }

    private func saveAgent() {
        let id = agentDraft.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        ElevenLabsKeychain.saveAgentId(id)
        agentDraft = ""
        agentFocused = false
        refresh()
    }

    private func removeAgent() {
        ElevenLabsKeychain.deleteAgentId()
        agentDraft = ""
        refresh()
    }

    private func mask(_ key: String) -> String {
        guard key.count > 4 else { return String(repeating: "•", count: 32) }
        return String(repeating: "•", count: 36) + key.suffix(4)
    }
}

private struct FieldBox: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.black.opacity(AppTheme.Opacity.muted))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        focused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.thin
                    )
            )
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: focused)
    }
}
