import AVFoundation
import Observation
import Speech

/// Dictation for the assistant. Runs on the device when the phone supports it, shows words as
/// they're heard, and finishes by itself after a short pause.
@MainActor
@Observable
final class SpeechInput {
    private(set) var transcript = ""
    private(set) var isListening = false
    var problem: String?

    /// Called with the final words when listening ends on its own or with `finish()`.
    var onFinished: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?
    private static let pause: Duration = .seconds(1.6)

    func start() async {
        guard !isListening else { return }
        problem = nil
        transcript = ""

        guard await Self.speechAllowed(), await AVAudioApplication.requestRecordPermission() else {
            problem = "Turn on Microphone and Speech Recognition for Get To It in Settings, or type instead."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now. Type instead."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            isListening = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                Task { @MainActor [weak self] in
                    guard let self, self.isListening else { return }
                    if let text { self.transcript = text; self.restartSilenceTimer() }
                    if isFinal || error != nil { self.finish() }
                }
            }
            restartSilenceTimer()
        } catch {
            problem = "Couldn't start the microphone. Type instead."
            stop()
        }
    }

    /// Stops listening and hands over what was heard.
    func finish() {
        guard isListening else { return }
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        if !words.isEmpty { onFinished?(words) }
    }

    /// Stops listening and drops what was heard.
    func stop() {
        silenceTimer?.cancel()
        silenceTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Ends listening after a pause, longer before the first word.
    private func restartSilenceTimer() {
        silenceTimer?.cancel()
        let wait: Duration = transcript.isEmpty ? .seconds(6) : Self.pause
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            if self?.transcript.isEmpty ?? true { self?.stop() } else { self?.finish() }
        }
    }

    private static func speechAllowed() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}
