import CryptoKit
import Foundation

/// 本地语音缓存（微信式）：收到过/合成过的 AI 语音按句存手机本地，
/// 重播零等待、不再重新合成；设置页可查看占用并手工清除。
/// 按文本内容作键（重播=播当初听到的那条），LRU 无上限——由用户在设置里清理。
final class VoiceCacheStore {
    static let shared = VoiceCacheStore()

    private let dir: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("tts-voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 键 = 文本 + 情绪标签：同一句话不同语气是不同音频；实时通道的即兴语音 tone 为空。
    private func fileURL(for text: String, tone: String) -> URL {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data("\(tone)|\(normalized)".utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(40)
        return dir.appendingPathComponent("\(name).audio")
    }

    func get(_ text: String, tone: String = "") -> Data? {
        try? Data(contentsOf: fileURL(for: text, tone: tone))
    }

    func put(_ data: Data, for text: String, tone: String = "") {
        guard data.isEmpty == false else { return }
        try? data.write(to: fileURL(for: text, tone: tone), options: [.atomic])
    }

    /// 缓存总大小（字节），设置页展示用。
    var totalBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    var totalBytesText: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    /// 清空全部语音缓存，返回释放的字节数。
    @discardableResult
    func clear() -> Int64 {
        let freed = totalBytes
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return freed
    }
}
