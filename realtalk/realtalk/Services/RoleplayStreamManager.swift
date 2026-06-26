import AVFoundation
import Combine
import Foundation

/// 沉浸式（方式2）后端语音流：WebSocket 持续连接，客户端录一句音频→commit，
/// 后端识别+评分并把推进的 AI 台词以 TTS 音频流推回；AI 朗读时检测到用户说话→发 interrupt 抢话打断。
/// 真正的识别/评分都在后端，本类只负责「录音+VAD+抢话+播 AI 音频+收发协议」。
@MainActor
final class RoleplayStreamManager: NSObject, ObservableObject {
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var aiAudioLevel: Double = 0
    @Published private(set) var isAISpeaking = false

    /// 一轮完整状态（RoleplayStateResponse 的 JSON），客户端据此刷新字幕/进度/评分。
    var onResultState: ((Data) -> Void)?
    /// 没听清等无状态提示。
    var onResultMessage: ((String) -> Void)?
    var onCompleted: (() -> Void)?
    var onError: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var guidanceMode = "realtime"

    // 录音 + VAD
    private var recorder: AVAudioRecorder?
    private var recURL: URL?
    private var meterTimer: Timer?
    private var heardSpeech = false
    private var silentTicks = 0
    private var bargeTicks = 0
    private let tick: TimeInterval = 0.1
    private let silenceThreshold: TimeInterval = 2.0
    private let speechLevel: Double = 0.12
    private let bargeLevel: Double = 0.2
    private let bargeNeeded = 3   // 连续 N 个 tick 高能量才算抢话，避免误触

    // 播放 AI 音频
    private var aiPlayer: AVAudioPlayer?
    private var aiQueue: [Data] = []
    private var incomingAudio = Data()
    private var receivingAudio = false
    private var active = false

    func start(streamURL: URL, guidanceMode: String) {
        stop()
        self.guidanceMode = guidanceMode
        active = true
        configureSession()
        let session = URLSession(configuration: .default)
        task = session.webSocketTask(with: streamURL)
        task?.resume()
        receiveLoop()
        startRecording()
    }

    func stop() {
        active = false
        sendJSON(["type": "bye"])
        meterTimer?.invalidate(); meterTimer = nil
        recorder?.stop(); recorder = nil
        if let u = recURL { try? FileManager.default.removeItem(at: u) }
        recURL = nil
        aiPlayer?.stop(); aiPlayer = nil
        aiQueue.removeAll()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isAISpeaking = false
        audioLevel = 0; aiAudioLevel = 0
    }

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .allowBluetoothHFP, .defaultToSpeaker])
        try? s.setActive(true, options: .notifyOthersOnDeactivation)
    }

    // MARK: 录音 + VAD + 抢话

    private func startRecording() {
        recorder?.stop()
        if let u = recURL { try? FileManager.default.removeItem(at: u) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-stream-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return }
        r.isMeteringEnabled = true
        guard r.record() else { return }
        recorder = r
        recURL = url
        heardSpeech = false
        silentTicks = 0
        bargeTicks = 0
        if meterTimer == nil {
            meterTimer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.meterTick() }
            }
        }
    }

    private func meterTick() {
        guard let r = recorder, active else { return }
        r.updateMeters()
        let level = max(0, min(1, (Double(r.averagePower(forChannel: 0)) + 50) / 50))
        audioLevel = level

        if isAISpeaking {
            if let p = aiPlayer, p.isPlaying {
                p.updateMeters()
                aiAudioLevel = max(0, min(1, (Double(p.averagePower(forChannel: 0)) + 50) / 50))
            }
            // 抢话：AI 朗读时持续高能量 → 打断
            if level >= bargeLevel {
                bargeTicks += 1
                if bargeTicks >= bargeNeeded {
                    bargeIn()
                }
            } else {
                bargeTicks = 0
            }
            return
        }

        // 普通 VAD：说话→静音到阈值即提交一句
        if level >= speechLevel {
            heardSpeech = true
            silentTicks = 0
        } else if heardSpeech {
            silentTicks += 1
            if Double(silentTicks) * tick >= silenceThreshold {
                commitUtterance()
            }
        }
    }

    private func bargeIn() {
        sendJSON(["type": "interrupt"])
        aiPlayer?.stop(); aiPlayer = nil
        aiQueue.removeAll()
        isAISpeaking = false
        aiAudioLevel = 0
        startRecording()   // 干净录这次抢话的内容
    }

    private func commitUtterance() {
        recorder?.stop()
        let url = recURL
        let heard = heardSpeech
        recURL = nil
        if heard, let url, let data = try? Data(contentsOf: url), data.count > 1200 {
            task?.send(.data(data)) { _ in }
            sendJSON(["type": "commit", "format": ".m4a", "guidance_mode": guidanceMode])
        }
        if let url { try? FileManager.default.removeItem(at: url) }
        startRecording()
    }

    // MARK: 收 AI 音频并顺序播放

    private func enqueueAI(_ data: Data) {
        aiQueue.append(data)
        if aiPlayer == nil { playNextAI() }
    }

    private func playNextAI() {
        guard aiQueue.isEmpty == false else {
            isAISpeaking = false
            aiAudioLevel = 0
            return
        }
        let data = aiQueue.removeFirst()
        guard let p = try? AVAudioPlayer(data: data) else { playNextAI(); return }
        p.delegate = self
        p.isMeteringEnabled = true
        aiPlayer = p
        isAISpeaking = true
        p.play()
    }

    // MARK: WebSocket 收发

    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.active else { return }
                switch result {
                case .failure:
                    self.onError?("连接已断开")
                    self.stop()
                case .success(let message):
                    switch message {
                    case .data(let data):
                        if self.receivingAudio { self.incomingAudio.append(data) }
                    case .string(let text):
                        self.handleEvent(text)
                    @unknown default:
                        break
                    }
                    self.receiveLoop()
                }
            }
        }
    }

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "ai_line":
            break   // 字幕由 result 的完整状态驱动（roleplay.messages）
        case "ai_audio_begin":
            receivingAudio = true
            incomingAudio.removeAll()
        case "ai_audio_end":
            receivingAudio = false
            if incomingAudio.isEmpty == false { enqueueAI(incomingAudio) }
            incomingAudio.removeAll()
        case "result":
            if let state = obj["state"], let data = try? JSONSerialization.data(withJSONObject: state) {
                onResultState?(data)
            } else if let feedback = obj["feedback"] as? String {
                onResultMessage?(feedback)
            }
        case "completed":
            onCompleted?()
        case "error":
            onError?(obj["detail"] as? String ?? "对话出错")
        default:
            break
        }
    }
}

extension RoleplayStreamManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.aiPlayer = nil
            self.playNextAI()
        }
    }
}
