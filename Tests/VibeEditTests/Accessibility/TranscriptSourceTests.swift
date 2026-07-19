import Testing
@testable import VibeEdit

@Suite("MockTranscriptSource seam")
struct TranscriptSourceTests {

    @Test func cannedPhrasesFlowThroughTheStream() async throws {
        let mock = MockTranscriptSource()
        let matcher = CommandMatcher()

        let consumer = Task { () -> [VoiceCommand] in
            var out: [VoiceCommand] = []
            for await phrase in mock.transcripts { out.append(matcher.match(phrase)) }
            return out
        }

        try await mock.start()
        mock.emit(["play", "sleep", "wake up", "zoom in"])
        await mock.stop()

        let commands = await consumer.value
        #expect(commands == [.play, .enterSleep, .exitSleep, .zoom(in: true)])
    }

    @Test func streamFinishesOnStop() async {
        let mock = MockTranscriptSource()
        let consumer = Task { () -> Int in
            var count = 0
            for await _ in mock.transcripts { count += 1 }
            return count
        }
        await mock.stop()
        #expect(await consumer.value == 0)
    }
}
