import AVFoundation
import Combine
import Foundation

/// 朗读 AI 台词。只用后端语音服务，普通朗读与实时对话使用用户选择的同一声音。
/// 后端不可用时跳过该句（字幕仍在），不再本机合成——避免机械音与错误发音误导学习。
/// 公开接口与原先一致（speak/stop/isSpeaking/audioLevel），上层对练编排无需改动。
@MainActor
final class VoicePromptPlayer: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var audioLevel: Double = 0

    /// 由 AppModel 注入：给定(文本, 是否走缓存)返回后端合成音频（调 /tts/speak）。cache=false 用于指导性内容（不入 Redis）。
    var audioProvider: ((String, Bool) async -> Data?)?

    private var player: AVAudioPlayer?
    private var queue: [String] = []
    private var cacheForQueue = true   // 本批文本是否走后端缓存（指导内容传 false）
    private var completion: (() -> Void)?
    private var levelTimer: Timer?
    private var fetchTask: Task<Void, Never>?

    func speak(_ text: String, cache: Bool = true, completion: (() -> Void)? = nil) {
        speak([text], cache: cache, completion: completion)
    }

    func speak(_ texts: [String], cache: Bool = true, completion: (() -> Void)? = nil) {
        let trimmed = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard trimmed.isEmpty == false else {
            completion?()
            return
        }
        stop()
        queue = trimmed
        cacheForQueue = cache
        self.completion = completion
        // 关键：不能切到 .playback！对话流的 AVAudioEngine（VoiceProcessingIO）还在录音，
        // 中途换类别会打断它并疯狂报 "auou/vpio render err: -1"，之后整个音频系统失灵。
        // 统一用与对话流一致的 .playAndRecord + .voiceChat（外放），已是该类别则不动。
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playAndRecord, mode: .voiceChat,
                                     options: [.duckOthers, .allowBluetoothHFP, .defaultToSpeaker])
            try? session.setActive(true, options: .notifyOthersOnDeactivation)
        }
        startLevelTimer()
        speakNext()
    }

    func stop() {
        fetchTask?.cancel()
        fetchTask = nil
        queue.removeAll()
        completion = nil
        player?.stop()
        player = nil
        stopLevelTimer()
        isSpeaking = false
        audioLevel = 0
    }

    private func speakNext() {
        guard queue.isEmpty == false else {
            isSpeaking = false
            audioLevel = 0
            stopLevelTimer()
            let finished = completion
            completion = nil
            finished?()
            return
        }
        let text = queue.removeFirst()
        isSpeaking = true
        guard let provider = audioProvider else { speakNext(); return }   // 无后端合成器 → 跳过（字幕仍在）
        let useCache = cacheForQueue
        fetchTask = Task { [weak self] in
            let data = await provider(text, useCache)
            guard let self, Task.isCancelled == false else { return }
            if let data, self.playData(data) { return }   // 播放完成会在 delegate 里继续下一句
            self.speakNext()                               // 后端音频不可用 → 跳过该句，不再本机合成
        }
    }

    private func playData(_ data: Data) -> Bool {
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.isMeteringEnabled = true
            player = p
            return p.play()
        } catch {
            return false
        }
    }

    // MARK: 音律跳动（后端音频用功率计）

    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.levelTick() }
        }
    }

    private func levelTick() {
        if let player, player.isPlaying {
            player.updateMeters()
            let power = player.averagePower(forChannel: 0)        // dB，约 -60...0
            audioLevel = max(0, min(1, (Double(power) + 50) / 50))
        } else {
            audioLevel *= 0.80
            if audioLevel < 0.02 { audioLevel = 0 }
        }
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
    }
}

extension VoicePromptPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            speakNext()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.player = nil
            speakNext()
        }
    }
}
