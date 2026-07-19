import Testing
@testable import VibeEdit

@Suite("CommandMatcher — default mode")
struct CommandMatcherTests {
    let m = CommandMatcher()

    @Test func transport() {
        #expect(m.match("play") == .play)
        #expect(m.match("Resume.") == .play)
        #expect(m.match("pause") == .pause)
        #expect(m.match("stop") == .pause)
        #expect(m.match("toggle playback") == .togglePlayback)
    }

    @Test func playhead() {
        #expect(m.match("next frame") == .stepFrame(forward: true))
        #expect(m.match("previous frame") == .stepFrame(forward: false))
        #expect(m.match("go to the start") == .jumpToStart)
        #expect(m.match("jump to end") == .jumpToEnd)
    }

    @Test func parameterizedSkip() {
        #expect(m.match("skip forward 10 seconds") == .skip(seconds: 10))
        #expect(m.match("go back 30 seconds") == .skip(seconds: -30))
        #expect(m.match("rewind 5 seconds") == .skip(seconds: -5))
        // No amount -> default step.
        #expect(m.match("skip forward") == .skip(seconds: 5))
    }

    @Test func editingAndView() {
        #expect(m.match("split") == .split)
        #expect(m.match("cut") == .split)
        #expect(m.match("delete") == .delete)
        #expect(m.match("undo") == .undo)
        #expect(m.match("zoom in") == .zoom(in: true))
        #expect(m.match("zoom out") == .zoom(in: false))
    }

    @Test func discoverability() {
        #expect(m.match("help") == .showHelp)
        #expect(m.match("what can I say") == .showHelp)
        #expect(m.match("close") == .hideHelp)
    }

    @Test func modeTransitions() {
        #expect(m.match("sleep") == .enterSleep)
        #expect(m.match("wake up") == .exitSleep)
    }

    @Test func spielbergIsNoLongerACommand() {
        // The Spielberg agent bracket was removed; the word maps to nothing now.
        if case .unrecognized = m.match("Spielberg") {} else { Issue.record("expected unrecognized") }
        if case .unrecognized = m.match("thank you Spielberg") {} else { Issue.record("expected unrecognized") }
    }

    @Test func fuzzyRecoversMishearings() {
        // One-character slips should still resolve to the nearest command.
        #expect(m.match("plays") == .play)
        #expect(m.match("pauze") == .pause)
        #expect(m.match("paws") == .pause)
        #expect(m.match("zoom inn") == .zoom(in: true))
    }

    @Test func unrelatedSpeechIsUnrecognized() {
        // Default mode must not fire on ambient chatter.
        if case .unrecognized = m.match("let's grab lunch after this") {} else {
            Issue.record("expected unrecognized")
        }
    }

}
