import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class SpeechCaptureManager: ObservableObject {
    enum CaptureError: LocalizedError {
        case recognizerUnavailable
        case permissionDenied
        case inputUnavailable

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return "当前语音识别服务不可用"
            case .permissionDenied:
                return "需要麦克风和语音识别权限"
            case .inputUnavailable:
                return "没有可用的音频输入"
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var partialText = ""
    @Published private(set) var statusText = "未开始"
    @Published private(set) var lastError: String?

    var onSegment: ((String, Date) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var shouldResumeAfterInterruption = false
    private var lastRecognitionText = ""
    private var interruptionObserver: NSObjectProtocol?

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let manager = self else { return }
            Task { @MainActor in
                manager.handleInterruption(typeValue: typeValue)
            }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    func start() async {
        guard isRecording == false else { return }
        lastError = nil
        statusText = "检查权限"

        guard await requestPermissions() else {
            lastError = CaptureError.permissionDenied.localizedDescription
            statusText = "权限不足"
            return
        }

        do {
            try configureAudioSession()
            try startRecognition()
            isRecording = true
            statusText = "采集中"
        } catch {
            stop(savePartial: false)
            lastError = error.localizedDescription
            statusText = "启动失败"
        }
    }

    func stop(savePartial: Bool) {
        silenceTimer?.invalidate()
        silenceTimer = nil

        if savePartial {
            emitSegmentIfNeeded(partialText, force: true)
        }

        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
        partialText = ""
        lastRecognitionText = ""
        statusText = "已停止"
    }

    private func requestPermissions() async -> Bool {
        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        let micGranted = await requestMicrophonePermission()

        return speechGranted && micGranted
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startRecognition() throws {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw CaptureError.recognizerUnavailable
        }

        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0 else {
            throw CaptureError.inputUnavailable
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognition(result: result, error: error)
            }
        }
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            updatePartial(text, final: result.isFinal)
        }

        if let error {
            lastError = error.localizedDescription
            statusText = isRecording ? "识别中断" : statusText
        }
    }

    private func updatePartial(_ text: String, final: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        partialText = trimmed
        scheduleSilenceFlush()

        if final {
            emitSegmentIfNeeded(trimmed, force: true)
        }
    }

    private func scheduleSilenceFlush() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 2.2, repeats: false) { [weak self] _ in
            guard let manager = self else { return }
            Task { @MainActor in
                manager.emitSegmentIfNeeded(manager.partialText, force: false)
            }
        }
    }

    private func emitSegmentIfNeeded(_ text: String, force: Bool) {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }

        if normalized == lastRecognitionText && force == false {
            return
        }

        if normalized.hasPrefix(lastRecognitionText), lastRecognitionText.isEmpty == false {
            normalized = String(normalized.dropFirst(lastRecognitionText.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard normalized.isEmpty == false else { return }
        lastRecognitionText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        onSegment?(normalized, Date())
    }

    private func handleInterruption(typeValue: UInt?) {
        guard
            let typeValue,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }

        switch type {
        case .began:
            shouldResumeAfterInterruption = isRecording
            if isRecording {
                stop(savePartial: true)
            }
            statusText = "Siri或系统音频占用，已暂停"
        case .ended:
            guard shouldResumeAfterInterruption else { return }
            shouldResumeAfterInterruption = false
            Task { await start() }
        @unknown default:
            break
        }
    }
}
