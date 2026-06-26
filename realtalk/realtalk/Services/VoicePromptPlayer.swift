import AVFoundation
import Combine
import Foundation

/// 朗读 AI 台词。优先用「后端 TTS」（可选音色、口音更自然），后端不可用时回退本机合成，保证总能出声。
/// 公开接口与原先一致（speak/stop/isSpeaking/audioLevel），上层对练编排无需改动。
@MainActor
final class VoicePromptPlayer: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var audioLevel: Double = 0

    /// 由 AppModel 注入：给定文本返回后端合成的音频数据（调 /tts/speak）。为 nil 或返回 nil 时回退本机合成。
    var audioProvider: ((String) async -> Data?)?

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var queue: [String] = []
    private var completion: (() -> Void)?
    private var levelTimer: Timer?
    private var fetchTask: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, completion: (() -> Void)? = nil) {
        speak([text], completion: completion)
    }

    func speak(_ texts: [String], completion: (() -> Void)? = nil) {
        let trimmed = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard trimmed.isEmpty == false else {
            completion?()
            return
        }
        stop()
        queue = trimmed
        self.completion = completion
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        startLevelTimer()
        speakNext()
    }

    func stop() {
        fetchTask?.cancel()
        fetchTask = nil
        queue.removeAll()
        completion = nil
        synthesizer.stopSpeaking(at: .immediate)
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
        if let provider = audioProvider {
            fetchTask = Task { [weak self] in
                let data = await provider(text)
                guard let self, Task.isCancelled == false else { return }
                if let data, self.playData(data) { return }   // 播放完成会在 delegate 里继续下一句
                self.speakFallback(text)                       // 后端音频不可用 → 本机合成兜底
            }
        } else {
            speakFallback(text)
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

    private func speakFallback(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice(for: Self.language(for: text))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        utterance.preUtteranceDelay = 0.06
        synthesizer.speak(utterance)
    }

    private static var voiceCache: [String: AVSpeechSynthesisVoice?] = [:]
    private static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        if let cached = voiceCache[language] { return cached }
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        let chosen = candidates.first { $0.quality == .premium }
            ?? candidates.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: language)
        voiceCache[language] = chosen
        return chosen
    }

    private static func language(for text: String) -> String {
        text.range(of: "\\p{Han}", options: .regularExpression) == nil ? "en-US" : "zh-CN"
    }

    // MARK: 音律跳动（后端音频用功率计，本机合成用逐词脉冲衰减）

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

    private func pulse(forWordLength length: Int) {
        audioLevel = min(1.0, 0.5 + Double(length) * 0.06)
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

extension VoicePromptPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in isSpeaking = true }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let length = characterRange.length
        Task { @MainActor in pulse(forWordLength: length) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in speakNext() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in isSpeaking = false }
    }
}
