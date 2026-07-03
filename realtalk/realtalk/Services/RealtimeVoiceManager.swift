@preconcurrency import AVFoundation
import Combine
import Foundation

/// 高级会员「实时语音大模型」对练客户端（需求第 4 项）。
///
/// 通过 WebSocket 连接后端 `/roleplay/voice`，后端只做透明转发并注入场景台词/护栏：
/// - 采集麦克风 → 重采样为 24kHz/PCM16 → base64 走 `input_audio_buffer.append` 事件上行；
/// - 接收 `response.audio.delta`（base64 PCM16）实时播放 AI 语音；
/// - 接收转写事件做字幕；用户开口（server VAD `speech_started`）即打断 AI 实现自然抢话；
/// - 结束时发送 `realtalk.end`，等待后端回传 `realtalk.review`（评分 + 中文分析）。
///
/// 后端不处理音频内容，护栏（只做口语练习、按场景台词、不越界、不涉政/敏感）由服务端 session 指令强制。
@MainActor
final class RealtimeVoiceManager: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case active
        case ending
        case ended
        case error(String)
    }

    struct Line: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        let text: String
        enum Role { case user, ai }
    }

    struct Review: Equatable {
        let score: Int
        let analysis: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript: [Line] = []
    @Published private(set) var review: Review?
    @Published private(set) var statusText = ""
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var aiSpeaking = false

    // 24kHz / 单声道：与 OpenAI Realtime API 的 pcm16 输入输出对齐
    private let pcm16Target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var inputConverter: AVAudioConverter?
    private var wsTask: URLSessionWebSocketTask?
    private var endTimeout: Task<Void, Never>?
    private var didStartPlaybackGraph = false
    // 方式3 断线重连：连接可恢复、客户端字幕保留；但实时模型是 provider 侧有状态，重连后模型上下文会重置（实时语义固有）
    private var rtToken = ""
    private var rtSessionId = ""
    private var rtTitle = ""
    private var reconnectAttempts = 0
    private let maxReconnect = 3
    private var reconnectTask: Task<Void, Never>?

    private lazy var urlSession: URLSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    var isBusy: Bool { phase == .connecting || phase == .active || phase == .ending }

    // MARK: 生命周期

    /// 开始一次语音对练：申请麦克风 → 配置音频 → 连接 WS → 起麦 → 让 AI 先开口。
    func start(token: String, sessionId: String, scenarioTitle: String) async {
        guard phase == .idle || isEnded else { return }
        resetState()
        rtToken = token; rtSessionId = sessionId; rtTitle = scenarioTitle
        reconnectAttempts = 0
        phase = .connecting
        statusText = "正在连接语音模型…"

        guard await requestMicrophonePermission() else {
            fail("需要麦克风权限才能进行语音对练")
            return
        }

        guard let url = makeSocketURL(token: token, sessionId: sessionId) else {
            fail("服务地址无效")
            return
        }

        // 先建连，麦克风的音频上行需要可用的 WS
        let task = urlSession.webSocketTask(with: url)
        wsTask = task
        task.resume()
        receiveNext()

        do {
            try configureAudioSession()
            try startAudioEngine()
        } catch {
            fail("音频启动失败：\(error.localizedDescription)")
            return
        }

        phase = .active
        statusText = scenarioTitle
        // 让 AI 按场景台词先开口（server VAD 之后随用户语音自然轮换）
        sendJSON(["type": "response.create"])
    }

    /// 结束并评分：停麦、通知后端结束，等待 `realtalk.review` 回传。
    func end() {
        guard phase == .active || phase == .connecting else { return }
        reconnectTask?.cancel(); reconnectTask = nil
        phase = .ending
        statusText = "正在生成评分与建议…"
        stopMicrophone()
        sendJSON(["type": "realtalk.end"])
        scheduleEndTimeout()
    }

    /// 直接退出（不等待评分），用于异常或用户放弃。
    func cancel() {
        reconnectTask?.cancel(); reconnectTask = nil
        endTimeout?.cancel(); endTimeout = nil
        teardownAudio()
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        if isEnded == false { phase = .ended }
    }

    private var isEnded: Bool {
        if case .ended = phase { return true }
        if case .error = phase { return true }
        return false
    }

    private func resetState() {
        transcript = []
        review = nil
        inputLevel = 0
        aiSpeaking = false
    }

    private func fail(_ message: String) {
        teardownAudio()
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        phase = .error(message)
        statusText = message
    }

    // MARK: 音频

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // voiceChat 模式启用回声消除，避免 AI 的声音被麦克风重新采集形成回授
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startAudioEngine() throws {
        if didStartPlaybackGraph == false {
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
            didStartPlaybackGraph = true
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw AudioError.noInput }
        inputConverter = AVAudioConverter(from: inputFormat, to: pcm16Target)
        installMicTap()

        engine.prepare()
        try engine.start()
    }

    private func stopMicrophone() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
        }
        inputLevel = 0
    }

    private func teardownAudio() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        playerNode.stop()
        inputLevel = 0
        aiSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func schedulePlayback(_ data: Data) {
        guard let buffer = RealtimeVoiceManager.makePlaybackBuffer(data, format: playbackFormat) else { return }
        if engine.isRunning == false { return }
        if playerNode.isPlaying == false { playerNode.play() }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// 用户开口即清空待播 AI 音频，实现自然打断。
    private func flushPlayback() {
        playerNode.stop()
        aiSpeaking = false
    }

    /// 安装麦克风 tap，把音频上行到「当前」WS（重连后重装即可改指新连接）。
    private func installMicTap() {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { return }
        let task = wsTask
        let converter = inputConverter
        let target = pcm16Target
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            if let converter,
               let data = RealtimeVoiceManager.pcm16Data(from: buffer, using: converter, target: target) {
                let payload = "{\"type\":\"input_audio_buffer.append\",\"audio\":\"\(data.base64EncodedString())\"}"
                task?.send(.string(payload)) { _ in }
            }
            let level = RealtimeVoiceManager.level(from: buffer)
            Task { @MainActor in self?.inputLevel = level }
        }
    }

    /// 方式3 断线重连：连接断了但仍在对练中 → 退避后重开 WS、把麦克风改发到新连接、让 AI 续话。
    /// 实时模型上下文在 provider 侧、重连即重置（模型不记得之前内容，实时语义固有）；客户端字幕(transcript)保留。
    private func scheduleRTReconnect() {
        wsTask?.cancel(with: .abnormalClosure, reason: nil)
        wsTask = nil
        reconnectAttempts += 1
        statusText = "网络不稳，正在重连…"
        let delay = min(6.0, pow(2.0, Double(reconnectAttempts - 1)))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.phase == .active else { return }
            self.reconnectRT()
        }
    }

    private func reconnectRT() {
        guard let url = makeSocketURL(token: rtToken, sessionId: rtSessionId) else {
            phase = .error("重连失败，请重试")
            return
        }
        let task = urlSession.webSocketTask(with: url)
        wsTask = task
        task.resume()
        receiveNext()
        installMicTap()                          // 麦克风音频改发到新连接
        sendJSON(["type": "response.create"])    // 让 AI 续话
        statusText = rtTitle
    }

    // MARK: WebSocket

    private func makeSocketURL(token: String, sessionId: String) -> URL? {
        guard var comps = URLComponents(url: AppConfig.apiBaseURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        comps.path = "/roleplay/voice"
        comps.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "session_id", value: sessionId),
        ]
        // URLQueryItem 不转义 '+'：老令牌可能含 '+'，服务端会解析成空格导致鉴权失败，强制编码为 %2B
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url
    }

    private func receiveNext() {
        // 在 @Sendable 完成闭包里只取出 Sendable 的纯文本，再用 Task 自带的 [weak self]
        // 跳回主线程，避免在并发闭包中捕获 self / 非 Sendable 的 Result。
        wsTask?.receive { result in
            let text: String?
            switch result {
            case .failure:
                text = nil
            case .success(let message):
                switch message {
                case .string(let value): text = value
                case .data(let data): text = String(data: data, encoding: .utf8)
                @unknown default: text = nil
                }
            }
            let closed = (try? result.get()) == nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if closed {
                    self.handleSocketClosed(reason: nil)
                    return
                }
                if let text { self.handleEvent(text) }
                self.receiveNext()
            }
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        wsTask?.send(.string(text)) { _ in }
    }

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

        reconnectAttempts = 0   // 收到任何事件即说明连接健康，复位重连计数

        switch type {
        case "response.audio.delta":
            if let b64 = object["delta"] as? String, let audio = Data(base64Encoded: b64) {
                aiSpeaking = true
                schedulePlayback(audio)
            }
        case "input_audio_buffer.speech_started":
            flushPlayback()
        case "response.audio.done", "response.done", "output_audio_buffer.stopped":
            aiSpeaking = false
        case "conversation.item.input_audio_transcription.completed":
            if let value = object["transcript"] as? String { appendLine(.user, value) }
        case "response.audio_transcript.done":
            if let value = object["transcript"] as? String { appendLine(.ai, value) }
        case "realtalk.review":
            let score = (object["score"] as? Int) ?? Int((object["score"] as? Double) ?? 0)
            let analysis = (object["analysis"] as? String) ?? ""
            review = Review(score: score, analysis: analysis)
            finishWithReview()
        case "error":
            if let err = object["error"] as? [String: Any], let message = err["message"] as? String {
                statusText = message
            }
        default:
            break
        }
    }

    private func appendLine(_ role: Line.Role, _ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        if transcript.last?.role == role && transcript.last?.text == trimmed { return }
        transcript.append(Line(role: role, text: trimmed))
    }

    private func scheduleEndTimeout() {
        endTimeout?.cancel()
        endTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            guard Task.isCancelled == false else { return }
            await MainActor.run {
                guard let self, self.isEnded == false else { return }
                if self.review == nil {
                    self.statusText = "评分超时，已结束本轮"
                }
                self.finishWithReview()
            }
        }
    }

    private func finishWithReview() {
        endTimeout?.cancel(); endTimeout = nil
        teardownAudio()
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        phase = .ended
        if statusText.isEmpty || statusText == "正在生成评分与建议…" {
            statusText = "本轮已结束"
        }
    }

    private func handleSocketClosed(reason: String?) {
        if isEnded { return }
        // 已请求结束但 socket 先关：保留已收到的评分（若有）
        if phase == .ending {
            finishWithReview()
            return
        }
        // 对练中网络抖动：自动重连（保留音频引擎与字幕），重试用尽才报错
        if phase == .active, reconnectAttempts < maxReconnect {
            scheduleRTReconnect()
            return
        }
        teardownAudio()
        wsTask = nil
        let message = reason?.isEmpty == false ? reason! : "语音连接已断开"
        phase = .error(message)
        statusText = message
    }

    // MARK: 纯函数音频转换（在实时音频线程调用，避免触碰主线程隔离状态）

    private nonisolated static func pcm16Data(
        from buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        target: AVAudioFormat
    ) -> Data? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, output.frameLength > 0, let channel = output.int16ChannelData else { return nil }
        return Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    private nonisolated static func makePlaybackBuffer(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = data.count / MemoryLayout<Int16>.size
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: Int16.self)
            for index in 0..<frames {
                destination[index] = Float(source[index]) / 32_768.0
            }
        }
        return buffer
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

    private enum AudioError: LocalizedError {
        case noInput
        var errorDescription: String? { "没有可用的音频输入" }
    }
}

extension RealtimeVoiceManager: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            if self.phase == .connecting { self.phase = .active }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) }
        let message = Self.closeMessage(code: closeCode, reason: text)
        Task { @MainActor in self.handleSocketClosed(reason: message) }
    }

    private nonisolated static func closeMessage(code: URLSessionWebSocketTask.CloseCode, reason: String?) -> String? {
        if let reason, reason.isEmpty == false { return reason }
        switch code.rawValue {
        case 4401: return "登录已失效，请重新登录"
        case 4404: return "场景练习不存在"
        case 4503: return "语音大模型未配置，请联系管理员"
        default: return nil
        }
    }
}
