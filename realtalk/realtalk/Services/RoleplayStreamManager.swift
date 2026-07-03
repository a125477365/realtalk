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
    @Published private(set) var isPaused = false   // 临时暂停：停录音停播报，连接保持，点按恢复

    /// 一轮完整状态（RoleplayStateResponse 的 JSON），客户端据此刷新字幕/进度/评分。
    var onResultState: ((Data) -> Void)?
    /// 没听清等无状态提示。
    var onResultMessage: ((String) -> Void)?
    var onCompleted: (() -> Void)?
    var onError: ((String) -> Void)?
    var onStatus: ((String) -> Void)?   // 「重连中/已重连」等提示
    var onCommitted: (() -> Void)?      // 一句录音已提交后端（用于「已发送，正在识别评分…」状态提示）
    // 自由对话（/freetalk/stream）事件：历史回放 + 双方逐句字幕(带中文翻译)。协议其余部分与沉浸式完全一致。
    var onFreeTalkHistory: (([(speaker: String, text: String)]) -> Void)?
    var onUserText: ((String, String) -> Void)?   // (text, translation)
    var onAIText: ((String, String) -> Void)?      // (text, translation)

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
    private let silenceThreshold: TimeInterval = 1.5   // 说完到发送的停顿判定，越小越跟手
    private let speechLevel: Double = 0.12
    private let bargeLevel: Double = 0.2
    private let bargeNeeded = 3   // 连续 N 个 tick 高能量才算抢话，避免误触

    // 播放 AI 音频
    private var aiPlayer: AVAudioPlayer?
    private var aiQueue: [Data] = []
    private var incomingAudio = Data()
    private var receivingAudio = false
    private var active = false
    // 断线重连：网络抖动时不直接报错停掉，自动重连；重连后后端回完整状态并补念当前待回应那句
    private var streamURL: URL?
    private var connected = false
    private var reconnectAttempts = 0
    private let maxReconnect = 5
    private var reconnectTask: Task<Void, Never>?

    func start(streamURL: URL, guidanceMode: String) {
        stop()
        self.streamURL = streamURL
        self.guidanceMode = guidanceMode
        active = true
        reconnectAttempts = 0
        configureSession()
        connectWS()   // 录音在收到 state 事件后开始（首连/重连都走这条路径）
    }

    private func connectWS() {
        guard active, let streamURL else { return }
        let session = URLSession(configuration: .default)
        task = session.webSocketTask(with: streamURL)
        task?.resume()
        receiveLoop()
    }

    private func scheduleReconnect() {
        guard active else { return }
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        reconnectAttempts += 1
        if reconnectAttempts > maxReconnect {
            onError?("网络已断开，请重试")
            stop()
            return
        }
        onStatus?("网络不稳，正在重连…")
        let delay = min(8.0, pow(2.0, Double(reconnectAttempts - 1)))   // 1,2,4,8,8 秒退避
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.active else { return }
            self.connectWS()
        }
    }

    /// 临时暂停/恢复：暂停时停录音+停 AI 朗读（不断开 WS），再点恢复聆听。
    func togglePause() {
        if isPaused {
            isPaused = false
            startRecording()
            return
        }
        isPaused = true
        recorder?.stop(); recorder = nil
        if let u = recURL { try? FileManager.default.removeItem(at: u) }
        recURL = nil
        sendJSON(["type": "interrupt"])
        aiPlayer?.stop(); aiPlayer = nil
        aiQueue.removeAll()
        isAISpeaking = false
        audioLevel = 0; aiAudioLevel = 0
    }

    func stop() {
        active = false
        connected = false
        isPaused = false
        reconnectTask?.cancel(); reconnectTask = nil
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
        guard connected else { return }   // 断线/重连期间只显示电平，不提交（避免把断线时的话丢进虚空）

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
            onCommitted?()
        }
        if let url { try? FileManager.default.removeItem(at: url) }
        startRecording()
    }

    // MARK: 收 AI 音频并顺序播放

    private func enqueueAI(_ data: Data) {
        guard isPaused == false else { return }   // 暂停期间到达的音频直接丢弃
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
                    self.connected = false
                    self.scheduleReconnect()   // 网络抖动自动重连，不直接报错停掉
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
        case "state":
            // 首连/重连：标记已连、复位重试计数，按后端回的完整状态恢复字幕/进度，丢弃断线残留音频，干净重录
            connected = true
            if reconnectAttempts > 0 { onStatus?("已重连") }
            reconnectAttempts = 0
            aiPlayer?.stop(); aiPlayer = nil
            aiQueue.removeAll()
            receivingAudio = false; incomingAudio.removeAll()
            isAISpeaking = false
            if let state = obj["state"], let d = try? JSONSerialization.data(withJSONObject: state) {
                onResultState?(d)
            }
            // 自由对话：state 直接带历史字幕列表
            if let msgs = obj["messages"] as? [[String: Any]] {
                onFreeTalkHistory?(msgs.map { (speaker: $0["speaker"] as? String ?? "ai", text: $0["text"] as? String ?? "") })
            }
            startRecording()
        case "user_text":
            if let t = obj["text"] as? String { onUserText?(t, obj["translation"] as? String ?? "") }
        case "ai_text":
            if let t = obj["text"] as? String { onAIText?(t, obj["translation"] as? String ?? "") }
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
