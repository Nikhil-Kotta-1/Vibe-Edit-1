import SwiftUI

/// Progress sheet for "Give Access" — shows the media-memory ingest running over the
/// folders the user picked, and the final result or an actionable error.
struct MediaMemoryIngestView: View {
    let service: MediaMemoryIngestService
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(AppTheme.Opacity.moderate)
            stateView(for: service.state)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider().opacity(AppTheme.Opacity.moderate)
            bottomBar
        }
        .frame(width: 560, height: 460)
        .background(
            AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent)
                .background(.ultraThinMaterial)
        )
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text("Give Access")
                .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(subtitle)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.lg)
    }

    private var subtitle: String {
        switch service.state {
        case .idle, .running:
            "Indexing your footage so the agent can search it by description."
        case .finished:
            "These folders are now searchable from the agent."
        case .failed:
            "Couldn't finish indexing."
        }
    }

    // MARK: - Body states

    @ViewBuilder
    private func stateView(for state: MediaMemoryIngestService.State) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .running(let progress):
            runningView(progress)
        case .finished(let summary):
            resultView(
                icon: "checkmark.circle.fill",
                tint: Color(AppTheme.TrackColor.audio),
                title: summary
            )
        case .failed(let message):
            resultView(
                icon: "exclamationmark.triangle.fill",
                tint: AppTheme.Status.errorColor,
                title: "Indexing failed",
                detail: message
            )
        }
    }

    private func runningView(_ progress: MediaMemoryIngestService.Progress) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.md) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("Indexed \(progress.filesProcessed) file\(progress.filesProcessed == 1 ? "" : "s") · \(progress.shotTally) shot\(progress.shotTally == 1 ? "" : "s")")
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .monospacedDigit()
                    if !progress.currentFile.isEmpty {
                        Text(progress.currentFile)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            logScroll
        }
        .padding(AppTheme.Spacing.xl)
    }

    private func resultView(icon: String, tint: Color, title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.smMd) {
                Image(systemName: icon)
                    .font(.system(size: AppTheme.FontSize.lg))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let detail {
                ScrollView {
                    Text(detail)
                        .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppTheme.Spacing.md)
                }
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(AppTheme.Background.baseColor)
                )
                .frame(maxHeight: .infinity)
            }
        }
        .padding(AppTheme.Spacing.xl)
    }

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    ForEach(service.log) { line in
                        Text(line.text)
                            .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                            .foregroundStyle(line.isError ? AppTheme.Status.errorColor : AppTheme.Text.tertiaryColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(AppTheme.Spacing.md)
            }
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Background.baseColor)
            )
            .frame(maxHeight: .infinity)
            .onChange(of: service.log.last?.id) { _, last in
                guard let last else { return }
                withAnimation(.easeOut(duration: AppTheme.Anim.hover)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            Spacer()
            if service.isRunning {
                Button("Cancel") { service.cancel() }
                    .buttonStyle(.capsule(.secondary))
            } else {
                Button("Close") { onClose() }
                    .buttonStyle(.capsule(.prominent))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.lg)
    }
}
