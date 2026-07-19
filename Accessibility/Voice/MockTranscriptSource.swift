import Foundation

/// A `TranscriptSource` driven by hand. Push canned utterances with `emit(...)`;
/// they flow through the exact same path the live microphone will use, so the
/// whole mode/dispatch system can be exercised in tests, previews, and a stdin
/// harness without any audio.
final class MockTranscriptSource: TranscriptSource, @unchecked Sendable {
    let transcripts: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private(set) var isRunning = false

    init() {
        var captured: AsyncStream<String>.Continuation!
        transcripts = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
    }

    func start() async throws { isRunning = true }

    func stop() async {
        isRunning = false
        continuation.finish()
    }

    /// Simulate the recognizer finalizing one utterance.
    func emit(_ phrase: String) { continuation.yield(phrase) }

    /// Convenience: finalize a sequence of utterances in order.
    func emit(_ phrases: [String]) { phrases.forEach { continuation.yield($0) } }
}
