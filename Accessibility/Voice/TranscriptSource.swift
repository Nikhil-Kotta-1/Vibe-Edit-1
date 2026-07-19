import Foundation

/// A source of finalized speech transcripts.
///
/// The mode controller consumes `transcripts` and never knows whether they come
/// from a mock, a file, or the live microphone — swapping engines is a one-line
/// change at construction (dependency inversion). The contract is that emitted
/// strings are *finalized* utterances, not partial hypotheses: a live engine
/// must wait until a result is stable before yielding.
protocol TranscriptSource: AnyObject, Sendable {
    /// Stable, finalized utterances. Finishes when the source stops.
    var transcripts: AsyncStream<String> { get }
    /// Begin capturing. Throws if the underlying engine can't start.
    func start() async throws
    /// Stop capturing and finish the stream.
    func stop() async
}
