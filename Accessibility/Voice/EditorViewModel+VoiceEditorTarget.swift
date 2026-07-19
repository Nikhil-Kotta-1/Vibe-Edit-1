import Foundation

/// Bridges `VoiceCommand` actions onto the real editor. `play()`, `pause()`, and
/// `togglePlayback()` already exist on `EditorViewModel` and satisfy the protocol
/// directly; the rest map here. Editor-specific math (frames, fps, zoom clamp)
/// stays on this side so the dispatcher itself is trivial and engine-agnostic.
extension EditorViewModel: VoiceEditorTarget {

    func stepFrame(forward: Bool) {
        forward ? stepForward() : stepBackward()
    }

    func skip(seconds: Double) {
        let frames = max(1, secondsToFrame(seconds: abs(seconds), fps: timeline.fps))
        seconds < 0 ? skipBackward(frames: frames) : skipForward(frames: frames)
    }

    func jumpToStart() { seekToFrame(0) }
    func jumpToEnd() { seekToFrame(timeline.totalFrames) }

    func zoom(in zoomIn: Bool) {
        let factor = zoomIn ? Zoom.magnifySensitivity : 1.0 / Zoom.magnifySensitivity
        zoomScale = max(minZoomScale, min(Zoom.max, zoomScale * factor))
    }

    func selectAtPlayhead() {
        let frame = currentFrame
        let ids = timeline.tracks.flatMap(\.clips)
            .filter { frame >= $0.startFrame && frame < $0.endFrame }
            .map(\.id)
        guard !ids.isEmpty else { return }   // nothing under the marker: keep the current selection
        selectedClipIds = Set(ids)
    }

    func split() { splitAtPlayhead() }
    func delete() { deleteSelectedClips() }
    func undo() { undoManager?.undo() }
    func redo() { undoManager?.redo() }
    func copyClips() { copySelectedClipsToClipboard() }
    func pasteClips() { pasteClipsAtPlayhead() }
}
