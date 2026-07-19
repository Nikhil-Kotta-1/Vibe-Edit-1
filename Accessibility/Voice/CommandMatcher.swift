import Foundation

/// Maps a raw transcript to a `VoiceCommand` for DEFAULT mode.
///
/// Two stages, cheapest-first:
///   1. Parameterized rules (regex) for commands that carry a value, e.g.
///      "skip forward 10 seconds".
///   2. A finite phrase table matched by *nearest command* — exact first, then
///      bounded edit-distance — so small mistranscriptions ("plates" -> "play")
///      still resolve. Because the vocabulary is finite and distinct, this is
///      far more reliable than open-ended transcription.
///
/// Pure Foundation and `Sendable`: it touches neither the mic nor the editor,
/// so it unit-tests fully without the app.
struct CommandMatcher: Sendable {

    struct Config: Sendable {
        /// Max edit distance as a fraction of phrase length for a fuzzy hit.
        /// Deliberately loose (~2 slips on a short word): in DEFAULT mode the
        /// vocabulary is finite and distinct, so near-misses like "paws"->"pause"
        /// should resolve, and unrelated chatter is still far enough to reject.
        var fuzzThreshold: Double = 0.4
        /// Default jump when "skip forward/back" carries no amount.
        var defaultSkipSeconds: Double = 5
    }

    var config: Config

    init(config: Config = Config()) {
        self.config = config
        self.phrases = Self.buildPhraseTable()
    }

    private let phrases: [(phrase: String, command: VoiceCommand)]

    /// Phrases to bias the on-device recognizer toward (Apple `contextualStrings`),
    /// which sharply improves accuracy for this small, fixed vocabulary.
    var contextualVocabulary: [String] { phrases.map { $0.phrase } }

    func match(_ transcript: String) -> VoiceCommand {
        let text = Self.normalize(transcript)
        guard !text.isEmpty else { return .unrecognized("") }

        if let param = parameterized(text) { return param }

        // Exact phrase first (longest phrase wins ties, e.g. "thank you
        // spielberg" beats "spielberg").
        if let exact = phrases
            .filter({ $0.phrase == text })
            .max(by: { $0.phrase.count < $1.phrase.count }) {
            return exact.command
        }

        // Nearest phrase within the bounded distance.
        var best: (command: VoiceCommand, score: Double)? = nil
        for entry in phrases {
            let dist = Self.levenshtein(text, entry.phrase)
            let limit = Int((Double(entry.phrase.count) * config.fuzzThreshold).rounded())
            guard dist <= max(1, limit) else { continue }
            let score = Double(dist) / Double(max(entry.phrase.count, 1))
            if best == nil || score < best!.score {
                best = (entry.command, score)
            }
        }
        return best?.command ?? .unrecognized(text)
    }

    // MARK: - Parameterized rules

    private func parameterized(_ text: String) -> VoiceCommand? {
        // "skip/go/move forward|back [by] <amount>"
        if let g = Self.capture(#"^(?:skip|go|move|jump)\s+(forward|forwards|ahead|back|backward|backwards)(?:\s+(?:by\s+)?(.+))?$"#, in: text) {
            let backward = ["back", "backward", "backwards"].contains(g[1] ?? "")
            let secs = g[2].flatMap(SpokenNumberParser.parseDurationSeconds) ?? config.defaultSkipSeconds
            return .skip(seconds: backward ? -secs : secs)
        }
        // forward-only verbs
        if let g = Self.capture(#"^(?:fast\s*forward|advance)\s+(?:by\s+)?(.+)$"#, in: text) {
            return g[1].flatMap(SpokenNumberParser.parseDurationSeconds).map { .skip(seconds: $0) }
        }
        // backward-only verbs
        if let g = Self.capture(#"^(?:rewind)\s+(?:by\s+)?(.+)$"#, in: text) {
            return g[1].flatMap(SpokenNumberParser.parseDurationSeconds).map { .skip(seconds: -$0) }
        }
        return nil
    }

    // MARK: - Phrase table

    private static func buildPhraseTable() -> [(String, VoiceCommand)] {
        let table: [(String, VoiceCommand)] = [
            // Transport
            ("play", .play),
            ("resume", .play),
            ("pause", .pause),
            ("stop", .pause),
            ("play pause", .togglePlayback),
            ("toggle", .togglePlayback),
            ("toggle playback", .togglePlayback),

            // Playhead
            ("next frame", .stepFrame(forward: true)),
            ("step forward", .stepFrame(forward: true)),
            ("previous frame", .stepFrame(forward: false)),
            ("last frame", .stepFrame(forward: false)),
            ("step back", .stepFrame(forward: false)),
            ("go to start", .jumpToStart),
            ("go to the start", .jumpToStart),
            ("go to beginning", .jumpToStart),
            ("jump to start", .jumpToStart),
            ("go to end", .jumpToEnd),
            ("go to the end", .jumpToEnd),
            ("jump to end", .jumpToEnd),

            // View
            ("zoom in", .zoom(in: true)),
            ("zoom out", .zoom(in: false)),

            // Editing
            ("select", .select),
            ("select clip", .select),
            ("select this", .select),
            ("split", .split),
            ("cut", .split),
            ("split clip", .split),
            ("delete", .delete),
            ("remove", .delete),
            ("delete clip", .delete),
            ("undo", .undo),
            ("redo", .redo),
            ("copy", .copy),
            ("paste", .paste),

            // Discoverability
            ("help", .showHelp),
            ("show help", .showHelp),
            ("what can i say", .showHelp),
            ("close", .hideHelp),
            ("close help", .hideHelp),

            // Mode transitions
            ("sleep", .enterSleep),
            ("sleep mode", .enterSleep),
            ("go to sleep", .enterSleep),
            ("wake up", .exitSleep),
            ("wake", .exitSleep),
        ]
        return table
    }

    // MARK: - Text utilities

    static func normalize(_ text: String) -> String {
        var t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        t = String(t.unicodeScalars.map { ".!?,;".unicodeScalars.contains($0) ? " " : Character($0) })
        return t.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
    }

    private static func capture(_ pattern: String, in text: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let sr = Range(r, in: text) else { return nil }
            return String(text[sr])
        }
    }

    /// Classic edit distance over Characters.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var curr = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[t.count]
    }
}
