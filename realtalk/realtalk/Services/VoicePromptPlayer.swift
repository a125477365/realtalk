import AVFoundation
import Combine
import Foundation

@MainActor
final class VoicePromptPlayer: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    /// AI 朗读时的跳动强度（0...1）。由合成器的真实逐词朗读进度事件
    /// (`willSpeakRangeOfSpeechString`) 驱动并随时间衰减，而非固定正弦动画，
    /// 因此提示圈是跟着 AI 实际说话的音节律动跳动的。
    @Published private(set) var audioLevel: Double = 0

    private let synthesizer = AVSpeechSynthesizer()
    private var queue: [SpokenPrompt] = []
    private var completion: (() -> Void)?
    private var decayTimer: Timer?

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
        queue = trimmed.map { SpokenPrompt(text: $0, language: Self.language(for: $0)) }
        self.completion = completion
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        startLevelDecay()
        speakNext()
    }

    func stop() {
        queue.removeAll()
        completion = nil
        synthesizer.stopSpeaking(at: .immediate)
        stopLevelDecay()
        isSpeaking = false
        audioLevel = 0
    }

    private func speakNext() {
        guard queue.isEmpty == false else {
            isSpeaking = false
            audioLevel = 0
            stopLevelDecay()
            let finished = completion
            completion = nil
            finished?()
            return
        }

        let prompt = queue.removeFirst()
        let utterance = AVSpeechUtterance(string: prompt.text)
        utterance.voice = AVSpeechSynthesisVoice(language: prompt.language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.88
        utterance.pitchMultiplier = 1.02
        synthesizer.speak(utterance)
    }

    // MARK: 音律跳动（基于真实朗读进度，逐词脉冲 + 衰减）

    private func startLevelDecay() {
        decayTimer?.invalidate()
        decayTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let player = self else { return }
            Task { @MainActor in
                player.decayTick()
            }
        }
    }

    private func decayTick() {
        audioLevel *= 0.80
        if audioLevel < 0.02 { audioLevel = 0 }
    }

    private func stopLevelDecay() {
        decayTimer?.invalidate()
        decayTimer = nil
    }

    private func pulse(forWordLength length: Int) {
        // 词越长脉冲越强，模拟真实说话的音节起伏
        audioLevel = min(1.0, 0.5 + Double(length) * 0.06)
    }

    private static func language(for text: String) -> String {
        text.range(of: "\\p{Han}", options: .regularExpression) == nil ? "en-US" : "zh-CN"
    }
}

private struct SpokenPrompt {
    let text: String
    let language: String
}

extension VoicePromptPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let length = characterRange.length
        Task { @MainActor in
            pulse(forWordLength: length)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            speakNext()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
        }
    }
}
