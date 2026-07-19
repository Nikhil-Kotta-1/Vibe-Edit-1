import AVFoundation
import Foundation
import Speech

/// Logs a fully-public diagnostic line. `NSLog("%@", x)` marks `x` private, hiding
/// it from `log show`/`log stream`; putting the text in the format string (with `%`
/// escaped) keeps it searchable. Temporary voice-bring-up instrumentation.
func voiceLog(_ message: String) {
    NSLog(message.replacingOccurrences(of: "%", with: "%%"))
}

/// Live on-device transcript source backed by Apple's Speech framework.
///
/// Runs `AVAudioEngine` into a `SFSpeechAudioBufferRecognitionRequest`, biased
/// toward the command vocabulary via `contextualStrings`, and emits each
/// finalized utterance into `transcripts`. On `isFinal` (or error) it restarts a
/// fresh recognition task so listening is continuous. Recognition is forced
/// on-device when supported: zero network, zero cost, low latency.
///
/// `pause()`/`resume()` keep the stream alive while temporarily stopping audio
/// capture — used to hand the mic to ElevenLabs during the Spielberg bracket
/// (see `VoiceControlCoordinator`) without ending the controller's consume loop.
final class AppleSpeechTranscriptSource: NSObject, TranscriptSource, @unchecked Sendable {

    let transcripts: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let contextualStrings: [String]

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isPaused = false
    private var isTapInstalled = false
    private var pendingFinalize: DispatchWorkItem?

    /// On-device recognition doesn't reliably mark `isFinal` on a pause, so once a
    /// partial result has held steady this long we force `endAudio()` to finalize.
    private static let silenceDebounce: TimeInterval = 0.8

    init(contextualStrings: [String] = []) {
        self.contextualStrings = contextualStrings
        var captured: AsyncStream<String>.Continuation!
        transcripts = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { captured = $0 }
        continuation = captured
        super.init()
    }

    // MARK: - TranscriptSource

    func start() async throws {
        voiceLog("🎙️VOICE start() begin")
        try await ensureAuthorization()
        voiceLog("🎙️VOICE auth ok")
        try installTapIfNeeded()
        try startEngine()
        let fmt = engine.inputNode.outputFormat(forBus: 0)
        voiceLog("🎙️VOICE start: sampleRate=\(fmt.sampleRate) channels=\(fmt.channelCount) onDevice=\(recognizer?.supportsOnDeviceRecognition ?? false) available=\(recognizer?.isAvailable ?? false)")
        beginTask()
    }

    func stop() async {
        isPaused = false
        cancelTask()
        if engine.isRunning { engine.stop() }
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        continuation.finish()
    }

    /// Temporarily stop feeding audio (hand the mic to ElevenLabs) without
    /// finishing the stream.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        cancelTask()
        if engine.isRunning { engine.stop() }
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        try? startEngine()
        beginTask()
    }

    // MARK: - Engine / task

    private func installTapIfNeeded() throws {
        guard !isTapInstalled else { return }
        let input = engine.inputNode
        // `installTap` asserts tapFormat.sampleRate == the input *hardware* rate.
        // On this machine the node's output format differs from its input rate, so
        // tapping with `outputFormat` aborts — use the hardware `inputFormat`.
        let format = input.inputFormat(forBus: 0)
        voiceLog("🎙️VOICE tap format sr=\(format.sampleRate) ch=\(format.channelCount)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceError.audioUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        isTapInstalled = true
    }

    private func startEngine() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    private func beginTask() {
        guard let recognizer, recognizer.isAvailable, !isPaused else {
            voiceLog("🎙️VOICE beginTask skipped (recognizer=\(recognizer != nil) available=\(recognizer?.isAvailable ?? false) paused=\(isPaused))")
            return
        }
        pendingFinalize?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = contextualStrings
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        voiceLog("🎙️VOICE beginTask: starting recognitionTask (onDevice=\(recognizer.supportsOnDeviceRecognition))")
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                voiceLog("🎙️VOICE result isFinal=\(result.isFinal) text=\"\(text)\"")
                if result.isFinal {
                    DispatchQueue.main.async { self.pendingFinalize?.cancel() }
                    if !text.isEmpty { self.continuation.yield(text) }
                    self.restart()
                } else {
                    DispatchQueue.main.async { self.scheduleFinalize(text) }
                }
            }
            if let error {
                voiceLog("🎙️VOICE error=\(error.localizedDescription)")
                self.restart()
            }
        }
    }

    /// (Main queue) re-arm a silence timer; if the partial holds steady for
    /// `silenceDebounce`, force `endAudio()` so the recognizer emits `isFinal`.
    private func scheduleFinalize(_ partial: String) {
        pendingFinalize?.cancel()
        guard !partial.isEmpty, !isPaused else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPaused else { return }
            voiceLog("🎙️VOICE silence→endAudio (stable=\"\(partial)\")")
            self.request?.endAudio()
        }
        pendingFinalize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silenceDebounce, execute: work)
    }

    /// Finalize the current task and immediately start a fresh one so listening
    /// is continuous.
    private func restart() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isPaused, self.engine.isRunning else { return }
            self.pendingFinalize?.cancel()
            self.cancelTask()
            self.beginTask()
        }
    }

    private func cancelTask() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
    }

    // MARK: - Permissions

    private func ensureAuthorization() async throws {
        let speechOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { throw VoiceError.speechDenied }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw VoiceError.micDenied }
        case .denied, .restricted:
            throw VoiceError.micDenied
        @unknown default:
            throw VoiceError.micDenied
        }
    }

    enum VoiceError: LocalizedError {
        case speechDenied, micDenied, audioUnavailable
        var errorDescription: String? {
            switch self {
            case .speechDenied: return "Enable Speech Recognition in System Settings → Privacy."
            case .micDenied: return "Enable microphone access in System Settings → Privacy."
            case .audioUnavailable: return "No audio input available — check the input device in System Settings → Sound."
            }
        }
    }
}
