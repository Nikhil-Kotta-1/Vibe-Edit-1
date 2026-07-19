import AVFoundation
import Foundation

enum DictationError: LocalizedError {
    case audioUnavailable
    var errorDescription: String? {
        switch self {
        case .audioUnavailable: return "No audio input available — check System Settings → Sound."
        }
    }
}

/// Captures mic audio and splits it into utterances using an energy VAD: while you speak it
/// records to a temp WAV, and once you pause it closes that file and yields its URL, then opens
/// a fresh one for the next utterance. Pure capture — transcription happens elsewhere.
///
/// `@unchecked Sendable`: the tap block runs on the audio I/O thread and is the only place that
/// touches the utterance state, mirroring `AppleSpeechTranscriptSource`. Exactly one engine owns
/// the mic at a time (the dictation/Apple toggles are mutually exclusive), so there is no second
/// consumer racing this one.
final class DictationAudioCapture: NSObject, @unchecked Sendable {

    let utterances: AsyncStream<URL>
    private let continuation: AsyncStream<URL>.Continuation

    private let engine = AVAudioEngine()
    private var isTapInstalled = false

    // Touched only on the audio thread (tap callback).
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var hasSpeech = false
    private var voicedSeconds = 0.0
    private var silentSeconds = 0.0

    /// RMS above this counts as speech. Loose enough for a quiet room mic.
    private static let rmsThreshold: Float = 0.015
    /// Pause length that ends an utterance.
    private static let silenceToEnd = 0.9
    /// Ignore sub-blips (clicks, single words cut off).
    private static let minUtterance = 0.25
    /// Hard cap so a long monologue still flushes.
    private static let maxUtterance = 30.0

    override init() {
        var captured: AsyncStream<URL>.Continuation!
        utterances = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
        super.init()
    }

    func start() throws {
        let input = engine.inputNode
        // Match the input HARDWARE format (see AppleSpeechTranscriptSource — tapping the output
        // format aborts on machines where the rates differ).
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.audioUnavailable }
        openFile(sampleRate: format.sampleRate, channels: format.channelCount)
        if !isTapInstalled {
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                self?.process(buffer, sampleRate: format.sampleRate)
            }
            isTapInstalled = true
        }
        engine.prepare()
        try engine.start()
        voiceLog("🎙️DICTATION capture started sr=\(format.sampleRate) ch=\(format.channelCount)")
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        if isTapInstalled { engine.inputNode.removeTap(onBus: 0); isTapInstalled = false }
        discardFile()
        continuation.finish()
    }

    // MARK: - Audio thread

    private func process(_ buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let file else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let samples = buffer.floatChannelData?[0] else { return }
        try? file.write(from: buffer)

        var sum: Float = 0
        for i in 0..<frames { let s = samples[i]; sum += s * s }
        let rms = (sum / Float(frames)).squareRoot()
        let dur = Double(frames) / sampleRate

        if rms >= Self.rmsThreshold {
            hasSpeech = true; voicedSeconds += dur; silentSeconds = 0
        } else {
            silentSeconds += dur
        }

        let ended = hasSpeech && silentSeconds >= Self.silenceToEnd && voicedSeconds >= Self.minUtterance
        if ended || (voicedSeconds + silentSeconds) >= Self.maxUtterance {
            finishUtterance(sampleRate: sampleRate, channels: buffer.format.channelCount)
        }
    }

    private func finishUtterance(sampleRate: Double, channels: AVAudioChannelCount) {
        let url = fileURL
        let speech = hasSpeech && voicedSeconds >= Self.minUtterance
        file = nil    // flush + close
        fileURL = nil
        if let url, speech {
            voiceLog("🎙️DICTATION utterance ready voiced=\(String(format: "%.1f", voicedSeconds))s")
            continuation.yield(url)
        } else if let url {
            try? FileManager.default.removeItem(at: url)
        }
        openFile(sampleRate: sampleRate, channels: channels)
    }

    private func openFile(sampleRate: Double, channels: AVAudioChannelCount) {
        hasSpeech = false; voicedSeconds = 0; silentSeconds = 0
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try? AVAudioFile(forWriting: url, settings: settings)
        fileURL = file != nil ? url : nil
    }

    private func discardFile() {
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        file = nil; fileURL = nil
    }
}
