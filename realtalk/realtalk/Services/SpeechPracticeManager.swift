import AVFoundation
import Combine
import Foundation

/// 练习时录用户这一句的音频，交给后端识别+评分（不再端侧 ASR，识别更宽容、可发音纠正）。
/// 公开接口与原先一致（start/stop/isListening/partialText/audioLevel/expectedPhrases），上层编排无需改动；
/// 区别是「说完一句」交付的是音频文件 URL（onAudioUtterance）而非文本。
@MainActor
final class SpeechPracticeManager: ObservableObject {
    enum PracticeSpeechError: LocalizedError {
        case permissionDenied
        case inputUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "需要麦克风权限"
            case .inputUnavailable: return "没有可用的音频输入"
            }
        }
    }

    @Published private(set) var isListening = false
    /// 保留字段：检测到用户在说话时置为占位串，供上层「回答超时」判断用户是否正在开口。
    @Published private(set) var partialText = ""
    @Published private(set) var statusText = "未开始"
    @Published private(set) var lastError: String?
    @Published private(set) var audioLevel: Double = 0

    /// 录完一句把音频文件 URL 交给上层上传（后端识别+评分+发音纠正）。
    var onAudioUtterance: ((URL) -> Void)?
    /// 兼容旧调用点：识别已移到后端并按场景目标句自动偏置，端侧无需再传。
    var expectedPhrases: [String] = []

    var currentPartial: String { partialText }

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var meterTimer: Timer?
    private var autoSubmitOnSilence = true
    private var heardSpeech = false
    private var silentTicks = 0
    private let silenceThreshold: TimeInterval = 2.6   // 静音多久算说完（沉浸式自动提交）
    private let tickInterval: TimeInterval = 0.1
    private let speechLevel: Double = 0.12             // 高于此判为「正在说话」

    func start(autoSubmit: Bool = true) async {
        guard isListening == false else { return }
        autoSubmitOnSilence = autoSubmit
        lastError = nil
        partialText = ""
        heardSpeech = false
        silentTicks = 0
        statusText = "准备听你说"

        guard await requestMicrophonePermission() else {
            lastError = PracticeSpeechError.permissionDenied.localizedDescription
            statusText = "权限不足"
            return
        }
        do {
            try configureAudioSession()
            try startRecording()
            isListening = true
            statusText = "请用英语说"
        } catch {
            stop(emit: false)
            lastError = error.localizedDescription
            statusText = "启动失败"
        }
    }

    func stop(emit: Bool) {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        let url = fileURL
        fileURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isListening = false
        audioLevel = 0
        partialText = ""
        statusText = "已停止"

        let size = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
        if emit, heardSpeech, let url, size > 1200 {
            onAudioUtterance?(url)   // 上层负责用完删除临时文件
        } else if let url {
            try? FileManager.default.removeItem(at: url)
        }
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

    private func startRecording() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-utt-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else { throw PracticeSpeechError.inputUnavailable }
        self.recorder = recorder
        self.fileURL = url
        meterTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.meterTick() }
        }
    }

    private func meterTick() {
        guard let recorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)    // dB，约 -60...0
        let level = max(0, min(1, (Double(power) + 50) / 50))
        audioLevel = level
        if level >= speechLevel {
            heardSpeech = true
            silentTicks = 0
            partialText = "…"
        } else if heardSpeech {
            silentTicks += 1
            if autoSubmitOnSilence, Double(silentTicks) * tickInterval >= silenceThreshold {
                stop(emit: true)
            }
        }
    }
}
