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

    // 采集（PCM 流式：AVAudioEngine tap → 16kHz mono Int16，边说边发）+ VAD
    private let engine = AVAudioEngine()
    private var engineRunning = false
    private var preroll: [Data] = []                  // 说话起点前的短暂预滚（避免吞掉句首）
    private let prerollMax = 5                        // ~0.5s
    private var streamingUtterance = false            // 说话已开始 → 帧实时发往后端
    private var heardSpeech = false
    private var silentTicks = 0
    private var bargeTicks = 0
    private var aiSpeakTicks = 0                      // AI 已连续朗读多少 tick（用于抢话宽限期）
    private let bargeGrace: TimeInterval = 1.0        // AI 开口后这段时间内不允许抢话，保证至少说完一句的开头
    private var suppressAiAudio = false               // 打断后丢弃该轮迟到的 AI 音频，直到下一次 commit
    private var utteranceTicks = 0
    private var voicedTicks = 0                       // 本句真正“像在说话”的 tick 数：太少=纯噪音，不上传
    private var noiseFloor: Double = 0.15            // 自适应环境噪声本底（关键：绝对阈值在有底噪时会一直判成“在说话”）
    private let tick: TimeInterval = 0.1
    private let silenceThreshold: TimeInterval = 1.0 // 说完到发送的停顿判定，越小越跟手
    private let maxUtterance: TimeInterval = 15       // 兜底：一句(含持续噪声)最长强制提交，避免永远卡在“聆听”
    private let speechMargin: Double = 0.10           // 高于本底这么多算“在说话”
    private let silenceMargin: Double = 0.045         // 低于本底+这么多算“静音”
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
        resetUtterance(sendReset: true)
        sendJSON(["type": "interrupt"])
        suppressAiAudio = true   // 暂停即打断：该轮迟到音频作废，恢复后从下一次 commit 重新开始
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
        if engineRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engineRunning = false
        }
        preroll.removeAll()
        aiPlayer?.stop(); aiPlayer = nil
        aiQueue.removeAll()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        isAISpeaking = false
        audioLevel = 0; aiAudioLevel = 0
    }

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        // .voiceChat 打开系统回声消除(AEC)：否则 AI 从扬声器放出的声音被麦克风拾到→被当成用户抢话→AI 刚说一个词就被打断
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .allowBluetoothHFP, .defaultToSpeaker])
        try? s.setActive(true, options: .notifyOthersOnDeactivation)
    }

    // MARK: 采集（PCM 流式）+ VAD + 抢话

    /// 启动/恢复采集：AVAudioEngine tap → 转 16kHz mono Int16 → 计电平驱动 VAD + 边说边发帧。
    private func startRecording() {
        resetUtterance(sendReset: false)
        guard engineRunning == false else { return }
        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)   // 系统回声消除：AI 外放不再混进麦克风
        let inFormat = input.outputFormat(forBus: 0)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return }
        input.installTap(onBus: 0, bufferSize: 1600, format: inFormat) { [weak self] buffer, _ in
            let ratio = 16000.0 / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var err: NSError?
            var fed = false
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
            let count = Int(out.frameLength)
            let data = Data(bytes: ch[0], count: count * 2)
            var acc: Double = 0
            for i in 0..<count { let v = Double(ch[0][i]) / 32768.0; acc += v * v }
            let level = min(1.0, (acc / Double(max(count, 1))).squareRoot() * 8.0)
            Task { @MainActor in self?.processChunk(data, level: level) }
        }
        engine.prepare()
        try? engine.start()
        engineRunning = true
    }

    private func resetUtterance(sendReset: Bool) {
        heardSpeech = false
        streamingUtterance = false
        silentTicks = 0
        bargeTicks = 0
        utteranceTicks = 0
        voicedTicks = 0
        preroll.removeAll()
        if sendReset { sendJSON(["type": "reset_audio"]) }   // 噪音废弃：清掉后端已积累的帧
    }

    /// 每 ~0.1s 一个 PCM 块：电平/VAD/抢话 + 说话中把帧实时发给后端（边说边传）。
    private func processChunk(_ data: Data, level: Double) {
        guard active else { return }
        audioLevel = level
        guard connected, isPaused == false else { return }

        if isAISpeaking {
            if let p = aiPlayer, p.isPlaying {
                p.updateMeters()
                aiAudioLevel = max(0, min(1, (Double(p.averagePower(forChannel: 0)) + 50) / 50))
            }
            aiSpeakTicks += 1
            let grace = Double(aiSpeakTicks) * tick >= bargeGrace
            if grace && level >= bargeLevel && level > aiAudioLevel + 0.12 {
                bargeTicks += 1
                if bargeTicks >= bargeNeeded { bargeIn() }
            } else {
                bargeTicks = 0
            }
            return   // AI 说话期间不上传帧（防 AI 声音混进用户话）
        }
        aiSpeakTicks = 0

        if !heardSpeech {
            noiseFloor = min(0.5, noiseFloor * 0.92 + level * 0.08)
        }
        let speechThresh = noiseFloor + speechMargin
        let silenceThresh = noiseFloor + silenceMargin

        if streamingUtterance {
            sendFrame(data)   // 边说边发
        } else {
            preroll.append(data)   // 说话前的预滚缓冲（保住句首）
            if preroll.count > prerollMax { preroll.removeFirst() }
        }

        if level >= speechThresh {
            if !heardSpeech {
                heardSpeech = true
                streamingUtterance = true
                for chunk in preroll { sendFrame(chunk) }
                preroll.removeAll()
            }
            silentTicks = 0
            utteranceTicks += 1
            voicedTicks += 1
        } else if heardSpeech {
            utteranceTicks += 1
            if level <= silenceThresh { silentTicks += 1 } else { silentTicks = 0 }
            if Double(silentTicks) * tick >= silenceThreshold {
                commitUtterance()
                return
            }
        }
        if heardSpeech && Double(utteranceTicks) * tick >= maxUtterance {
            commitUtterance()
        }
    }

    private func sendFrame(_ data: Data) {
        task?.send(.data(data)) { _ in }
    }

    private func bargeIn() {
        sendJSON(["type": "interrupt"])
        suppressAiAudio = true   // 被打断的这轮就此作废：其后迟到的 AI 音频全部丢弃，直到下一次 commit
        aiPlayer?.stop(); aiPlayer = nil
        aiQueue.removeAll()
        isAISpeaking = false
        aiAudioLevel = 0
        resetUtterance(sendReset: true)   // 干净开始这次抢话（清后端残留帧）
    }

    private func commitUtterance() {
        // 噪音门槛：真人声时长太短(<0.4s)视为纯噪音——通知后端清掉已发帧，静默回到聆听
        let voicedEnough = heardSpeech && Double(voicedTicks) * tick >= 0.4
        if voicedEnough {
            suppressAiAudio = false   // 新一轮开始，恢复接收 AI 音频
            sendJSON(["type": "commit", "format": "pcm16", "sample_rate": 16000, "guidance_mode": guidanceMode])
            onCommitted?()
            resetUtterance(sendReset: false)
        } else {
            resetUtterance(sendReset: true)
        }
    }


    // MARK: 收 AI 音频并顺序播放

    private func enqueueAI(_ data: Data) {
        guard isPaused == false, suppressAiAudio == false else { return }   // 暂停/被打断流程的迟到音频直接丢弃
        aiQueue.append(data)
        if aiPlayer == nil { playNextAI() }
    }

    private func playNextAI() {
        guard aiQueue.isEmpty == false else {
            let wasSpeaking = isAISpeaking
            isAISpeaking = false
            aiAudioLevel = 0
            // 关键：AI 刚说完 → 立刻重开一段干净录音。否则录音文件里带着 AI 从扬声器放出的整段声音，
            // 转写会把 AI 的话混进用户的话（字幕里用户气泡出现 AI 台词）。
            if wasSpeaking, active, connected { startRecording() }
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
        case "notice":
            // 可恢复的轻提示（没听清/噪音等）：显示一下即可，流程回到聆听，绝不当错误中断
            onResultMessage?(obj["detail"] as? String ?? "")
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
