import Combine
import Foundation

@MainActor
final class TranscriptStore: ObservableObject {
    enum TimeFilter: String, CaseIterable, Identifiable {
        case lastHour
        case today
        case custom
        case allRetained

        var id: String { rawValue }

        var title: String {
            switch self {
            case .lastHour:
                return "最近1小时"
            case .today:
                return "今天"
            case .custom:
                return "自定义"
            case .allRetained:
                return "近3天"
            }
        }
    }

    @Published private(set) var segments: [TranscriptSegment] = []

    private let retention: TimeInterval = TimeInterval(AppConfig.localRetentionDays * 24 * 60 * 60)
    private let fileURL: URL

    init() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = baseURL.appendingPathComponent("RealTalk", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("transcripts.json")
        load()
        pruneExpired()
    }

    var pendingUpload: [TranscriptSegment] {
        segments.filter { $0.uploadedAt == nil }
    }

    func addSegment(text: String, at date: Date = Date(), source: String = "speech") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        segments.append(TranscriptSegment(timestamp: date, text: trimmed, source: source))
        segments.sort { $0.timestamp > $1.timestamp }
        pruneExpired()
        save()
    }

    func markUploaded(ids: [UUID]) {
        guard ids.isEmpty == false else { return }
        let now = Date()
        let idSet = Set(ids)
        for index in segments.indices where idSet.contains(segments[index].id) {
            segments[index].uploadedAt = now
        }
        save()
    }

    func segments(for filter: TimeFilter, customStart: Date, customEnd: Date) -> [TranscriptSegment] {
        let now = Date()
        let start: Date
        let end: Date

        switch filter {
        case .lastHour:
            start = now.addingTimeInterval(-60 * 60)
            end = now
        case .today:
            start = Calendar.current.startOfDay(for: now)
            end = now
        case .custom:
            start = min(customStart, customEnd)
            end = max(customStart, customEnd)
        case .allRetained:
            start = now.addingTimeInterval(-retention)
            end = now
        }

        return segments
            .filter { $0.timestamp >= start && $0.timestamp <= end }
            .sorted { $0.timestamp > $1.timestamp }
    }

    func dateRange(for filter: TimeFilter, customStart: Date, customEnd: Date) -> (Date, Date) {
        let now = Date()
        switch filter {
        case .lastHour:
            return (now.addingTimeInterval(-60 * 60), now)
        case .today:
            return (Calendar.current.startOfDay(for: now), now)
        case .custom:
            return (min(customStart, customEnd), max(customStart, customEnd))
        case .allRetained:
            return (now.addingTimeInterval(-retention), now)
        }
    }

    func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-retention)
        let kept = segments.filter { $0.timestamp >= cutoff }
        if kept.count != segments.count {
            segments = kept
            save()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([TranscriptSegment].self, from: data) {
            segments = decoded.sorted { $0.timestamp > $1.timestamp }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(segments) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
