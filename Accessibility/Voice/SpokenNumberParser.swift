import Foundation

/// Parses spoken numbers, ordinals, durations, and timecodes out of transcript
/// fragments. Pure Foundation so it unit-tests without the app.
enum SpokenNumberParser {

    private static let units: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "a": 1, "an": 1,
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19, "twentieth": 20, "last": -1,
    ]

    /// A 1-based index: "3", "third", "three". Returns -1 for "last".
    static func parseIndex(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = Int(t) { return n }
        if let o = ordinals[t] { return o }
        return parseInteger(t)
    }

    /// A plain integer that may be spelled across words: "twenty one" -> 21.
    static func parseInteger(_ text: String) -> Int? {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return nil }
        var total = 0, current = 0, matched = false
        for token in tokens {
            if let d = Int(token) { current += d; matched = true }
            else if let u = units[token] { current += u; matched = true }
            else if let t = tens[token] { current += t; matched = true }
            else if token == "hundred" { current = max(current, 1) * 100; matched = true }
            else if token == "thousand" { total += max(current, 1) * 1000; current = 0; matched = true }
            else { return matched ? nil : nil }
        }
        return matched ? total + current : nil
    }

    /// A relative/absolute duration in seconds:
    /// "5 seconds", "two minutes", "1 minute 30", "a minute and a half", "90 seconds", "1:30".
    static func parseDurationSeconds(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let colon = parseColonClock(t) { return colon }

        let tokens = tokenize(t)
        guard !tokens.isEmpty else { return nil }

        var seconds = 0.0
        var current: Double? = nil
        var sawUnit = false
        var lastUnit: Double? = nil    // for trailing "...and a half"
        var i = 0

        while i < tokens.count {
            let token = tokens[i]
            if token == "and" { i += 1; continue }

            if token == "half" {
                // "half [a] <unit>" or "<n> and a half <unit>" -> fractional unit.
                var j = i + 1
                if j < tokens.count, tokens[j] == "a" || tokens[j] == "an" { j += 1 }
                if j < tokens.count, let u = unitSeconds(tokens[j]) {
                    seconds += ((current ?? 0) + 0.5) * u
                    current = nil; sawUnit = true; lastUnit = u
                    i = j + 1
                } else {
                    // Trailing half refers to the last unit said ("a minute and a half").
                    seconds += 0.5 * (lastUnit ?? 1)
                    i += 1
                }
                continue
            }

            // "a/an" only counts as 1 when it directly quantifies a unit ("a minute").
            if token == "a" || token == "an" {
                if i + 1 < tokens.count, unitSeconds(tokens[i + 1]) != nil {
                    current = (current ?? 0) + 1
                }
                i += 1; continue
            }

            if let u = unitSeconds(token) {
                seconds += (current ?? 1) * u; current = nil; sawUnit = true; lastUnit = u
                i += 1; continue
            }
            if let d = Double(token) { current = (current ?? 0) + d; i += 1; continue }
            if let n = wordValue(token) { current = (current ?? 0) + Double(n); i += 1; continue }
            return sawUnit ? seconds : nil
        }

        // A trailing bare number with no unit is treated as seconds ("skip 5").
        if let c = current { seconds += c }
        return (sawUnit || seconds > 0) ? seconds : nil
    }

    private static func unitSeconds(_ token: String) -> Double? {
        switch token {
        case "hour", "hours", "hr", "hrs": return 3600
        case "minute", "minutes", "min", "mins": return 60
        case "second", "seconds", "sec", "secs": return 1
        default: return nil
        }
    }

    /// An absolute position. Accepts the same forms as durations plus clock forms.
    static func parseTimecodeSeconds(_ text: String) -> Double? {
        parseDurationSeconds(text)
    }

    // MARK: - Internals

    private static func wordValue(_ token: String) -> Int? {
        units[token] ?? tens[token] ?? ordinals[token]
    }

    /// "1:30" -> 90, "1:02:03" -> 3723. Two fields = mm:ss, three = hh:mm:ss.
    private static func parseColonClock(_ text: String) -> Double? {
        guard text.contains(":") else { return nil }
        let parts = text.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        let nums = parts.compactMap { Int($0) }
        if nums.count == 2 { return Double(nums[0] * 60 + nums[1]) }
        return Double(nums[0] * 3600 + nums[1] * 60 + nums[2])
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
