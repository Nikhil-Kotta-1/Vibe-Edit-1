import AppKit
import SwiftUI

/// Non-modal window hosting the media-memory ingest console. Reopenable from the
/// toolbar status tag while the job keeps running in the background.
@MainActor
final class MediaMemoryConsoleWindowController: NSWindowController {
    static let shared = MediaMemoryConsoleWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Media Memory"
        window.setFrameAutosaveName("VibeEditMediaMemoryConsole")
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = AppTheme.Background.base.withAlphaComponent(0.4)
        window.isOpaque = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        super.init(window: window)

        let view = MediaMemoryIngestView(service: .shared) { [weak self] in
            self?.window?.close()
        }
        window.contentViewController = NSHostingController(rootView: view.tint(AppTheme.Accent.primary))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
