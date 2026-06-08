import AVFoundation
import Combine
import Foundation

@MainActor
final class VoicePromptPlayer: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var queue: [SpokenPrompt] = []
    private var completion: (() -> Void)?

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
        speakNext()
    }

    func stop() {
        queue.removeAll()
        completion = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func speakNext() {
        guard queue.isEmpty == false else {
            isSpeaking = false
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
