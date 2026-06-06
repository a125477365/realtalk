import Foundation

struct TranscriptSegment: Identifiable, Codable, Equatable {
    var id: UUID
    var timestamp: Date
    var text: String
    var source: String
    var uploadedAt: Date?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        text: String,
        source: String = "speech",
        uploadedAt: Date? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.source = source
        self.uploadedAt = uploadedAt
    }
}

extension TranscriptSegment {
    var shortTime: String {
        timestamp.formatted(date: .omitted, time: .shortened)
    }

    var dayLabel: String {
        timestamp.formatted(date: .abbreviated, time: .omitted)
    }
}
