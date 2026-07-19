import Foundation

/// Runs `media-memory/ingest.py` as a subprocess to index folders the user grants
/// access to, streaming its progress into observable state for the "Give Access" sheet.
@MainActor
@Observable
final class MediaMemoryIngestService {
    static let shared = MediaMemoryIngestService()
    private init() {}

    enum State: Equatable {
        case idle
        case running(Progress)
        case finished(summary: String)
        case failed(message: String)
    }

    struct Progress: Equatable {
        var filesProcessed = 0
        var currentFile = ""
        var shotTally = 0
        var scanningRoots: String?
    }

    struct LogLine: Identifiable, Equatable {
        let id: Int
        let text: String
        let isError: Bool
    }

    private(set) var state: State = .idle
    private(set) var log: [LogLine] = []

    private static let logCap = 200
    @ObservationIgnored private var nextLogID = 0
    @ObservationIgnored private var sawDone = false
    @ObservationIgnored private var wasCancelled = false
    @ObservationIgnored private var stdoutText = ""
    @ObservationIgnored private var stderrTail: [String] = []

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var consumeTask: Task<Void, Never>?

    private static let fileLine = #/^\s*\[(\d+)\]\s+(.+?)\s+→\s+(\d+) shot/#
    private static let scanningLine = #/^Scanning:\s*(.+)$/#
    private static let doneLine = #/^Done:/#

    var isRunning: Bool { if case .running = state { return true }; return false }

    func start(folders: [URL]) {
        guard !isRunning else { return }
        reset()

        let python = MediaMemoryConfig.venvPython
        let script = MediaMemoryConfig.ingestScript
        let fm = FileManager.default
        guard fm.fileExists(atPath: python.path) else {
            state = .failed(message: missingToolMessage(missing: python.path))
            return
        }
        guard fm.fileExists(atPath: script.path) else {
            state = .failed(message: missingToolMessage(missing: script.path))
            return
        }

        state = .running(Progress())

        let process = Process()
        process.executableURL = python
        process.currentDirectoryURL = MediaMemoryConfig.directory
        process.arguments = ["ingest.py", "--paths"] + folders.map(\.path)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        self.process = process

        let stream = AsyncStream<StreamEvent> { continuation in
            let outBuffer = LineBuffer()
            let errBuffer = LineBuffer()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    if let rest = outBuffer.flush() { continuation.yield(.stdout(rest)) }
                    handle.readabilityHandler = nil
                    return
                }
                for line in outBuffer.consume(data) { continuation.yield(.stdout(line)) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    if let rest = errBuffer.flush() { continuation.yield(.stderr(rest)) }
                    handle.readabilityHandler = nil
                    return
                }
                for line in errBuffer.consume(data) { continuation.yield(.stderr(line)) }
            }
            process.terminationHandler = { proc in
                continuation.yield(.finished(proc.terminationStatus))
                continuation.finish()
            }
            do {
                try process.run()
            } catch {
                continuation.yield(.stderr("Failed to launch ingest: \(error.localizedDescription)"))
                continuation.yield(.finished(-1))
                continuation.finish()
            }
        }

        consumeTask = Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }
    }

    func cancel() {
        wasCancelled = true
        process?.terminate()
    }

    // MARK: - Event handling

    private func handle(_ event: StreamEvent) {
        switch event {
        case .stdout(let line):
            stdoutText += line + "\n"
            append(line, isError: false)
            parse(line)
        case .stderr(let line):
            stderrTail.append(line)
            if stderrTail.count > 12 { stderrTail.removeFirst() }
            append(line, isError: true)
        case .finished(let status):
            finish(status: status)
        }
    }

    private func parse(_ line: String) {
        guard case .running(var progress) = state else { return }
        if let match = line.firstMatch(of: Self.scanningLine) {
            progress.scanningRoots = String(match.1)
            state = .running(progress)
            return
        }
        if let match = line.firstMatch(of: Self.fileLine) {
            progress.filesProcessed = Int(match.1) ?? progress.filesProcessed
            progress.currentFile = String(match.2)
            progress.shotTally += Int(match.3) ?? 0
            state = .running(progress)
            return
        }
        if line.firstMatch(of: Self.doneLine) != nil {
            sawDone = true
        }
    }

    private func finish(status: Int32) {
        process?.standardOutput = nil
        process?.standardError = nil
        process = nil
        consumeTask = nil

        if wasCancelled {
            let done: Int? = if case .running(let p) = state { p.filesProcessed } else { nil }
            state = .finished(summary: done.map { "Stopped after \($0) file\($0 == 1 ? "" : "s")." } ?? "Stopped.")
        } else if sawDone, let summary = lastDoneLine() {
            state = .finished(summary: summary)
        } else if status == 0 {
            state = .finished(summary: "Done.")
        } else if status == 2, !stdoutText.isEmpty {
            // Preflight gate failed — the actionable report is on stdout.
            state = .failed(message: stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            let tail = stderrTail.joined(separator: "\n")
            state = .failed(message: tail.isEmpty ? "Ingest exited with code \(status)." : tail)
        }
    }

    // MARK: - Helpers

    private func reset() {
        log.removeAll()
        nextLogID = 0
        sawDone = false
        wasCancelled = false
        stdoutText = ""
        stderrTail.removeAll()
    }

    private func append(_ text: String, isError: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        log.append(LogLine(id: nextLogID, text: trimmed, isError: isError))
        nextLogID += 1
        if log.count > Self.logCap { log.removeFirst(log.count - Self.logCap) }
    }

    private func lastDoneLine() -> String? {
        stdoutText
            .split(separator: "\n")
            .last { $0.hasPrefix("Done:") }
            .map(String.init)
    }

    private func missingToolMessage(missing: String) -> String {
        """
        Can't find the media-memory tool at \(MediaMemoryConfig.directory.path).
        Missing: \(missing)

        Set it up (see media-memory/SETUP.md), or point VibeEdit at it with the \
        MEDIA_MEMORY_DIR environment variable.
        """
    }
}

private enum StreamEvent: Sendable {
    case stdout(String)
    case stderr(String)
    case finished(Int32)
}

/// Accumulates partial pipe reads and emits whole lines. Captured into the pipe's
/// `@Sendable` readabilityHandler; the handler runs serially per handle, but the lock
/// makes the `@unchecked Sendable` honest.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""

    func consume(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let idx = pending.firstIndex(of: "\n") {
            lines.append(String(pending[pending.startIndex..<idx]))
            pending = String(pending[pending.index(after: idx)...])
        }
        return lines
    }

    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        defer { pending = "" }
        return pending.isEmpty ? nil : pending
    }
}
