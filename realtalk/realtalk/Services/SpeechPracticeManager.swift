import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class SpeechPracticeManager: ObservableObject {
    enum PracticeSpeechError: LocalizedError {
        case recognizerUnavailable
        case permissionDenied
        case inputUnavailable

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                return "英语语音识别服务不可用"
            case .permissionDenied:
                return "需要麦克风和语音识别权限"
            case .inputUnavailable:
                return "没有可用的音频输入"
            }
        }
    }

    @Published private(set) var isListening = false
    @Published private(set) var partialText = ""
    @Published private(set) var statusText = "未开始"
    @Published private(set) var lastError: String?
    @Published private(set) var audioLevel: Double = 0

    var onUtterance: ((String) -> Void)?
    /// 当前这句的目标英文（场景台词），作为识别上下文偏置，提升口语转写准确度。
    var expectedPhrases: [String] = []

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var emittedText = ""
    /// 沉浸式：静音一段时间自动提交；手工触发式：关闭自动提交，由用户松手时提交。
    private var autoSubmitOnSilence = true
    /// 静音判定时长：参考主流口语 App，给思考停顿留足时间，避免没说完就当作说完。
    private let silenceThreshold: TimeInterval = 2.6

    var currentPartial: String { partialText }

    func start(autoSubmit: Bool = true) async {
        guard isListening == false else { return }
        autoSubmitOnSilence = autoSubmit
        lastError = nil
        partialText = ""
        emittedText = ""
        statusText = "准备听你说"

        guard await requestPermissions() else {
            lastError = PracticeSpeechError.permissionDenied.localizedDescription
            statusText = "权限不足"
            return
        }

        do {
            try configureAudioSession()
            try startRecognition()
            isListening = true
            statusText = "请用英语说"
        } catch {
            stop(emit: false)
            lastError = error.localizedDescription
            statusText = "启动失败"
        }
    }

    func stop(emit: Bool) {
        silenceTimer?.invalidate()
        silenceTimer = nil

        if emit {
            emitCurrentUtterance()
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

        isListening = false
        audioLevel = 0
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
            mode: .spokenAudio,
            options: [.duckOthers, .allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startRecognition() throws {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw PracticeSpeechError.recognizerUnavailable
        }

        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // 用当前场景台词做上下文偏置，提升对目标句的转写准确度（不限制只能说这句）
        if expectedPhrases.isEmpty == false {
            request.contextualStrings = expectedPhrases
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw PracticeSpeechError.inputUnavailable
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request, weak self] buffer, _ in
            request?.append(buffer)
            let level = Self.level(from: buffer)
            Task { @MainActor in
                self?.audioLevel = level
            }
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
            partialText = result.bestTranscription.formattedString
            // 手工触发式：不自动提交，由用户松手决定
            if autoSubmitOnSilence {
                scheduleAutoSubmit()
                if result.isFinal {
                    stop(emit: true)
                }
            }
        }

        if let error {
            lastError = error.localizedDescription
            if isListening {
                statusText = "识别中断"
            }
        }
    }

    private func scheduleAutoSubmit() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            guard let manager = self else { return }
            Task { @MainActor in
                manager.stop(emit: true)
            }
        }
    }

    private func emitCurrentUtterance() {
        let text = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false, text != emittedText else { return }
        emittedText = text
        onUtterance?(text)
    }

    private nonisolated static func level(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<frameCount {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameCount))
        return min(1, max(0, Double(rms) * 24))
    }
}
