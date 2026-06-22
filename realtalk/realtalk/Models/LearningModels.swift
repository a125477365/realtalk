import Foundation

struct ChatMessage: Identifiable, Equatable {
    enum Sender: Equatable {
        case user
        case assistant
        case system
    }

    let id: UUID
    let sender: Sender
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), sender: Sender, text: String, createdAt: Date = Date()) {
        self.id = id
        self.sender = sender
        self.text = text
        self.createdAt = createdAt
    }
}

struct DialogueLine: Identifiable, Codable, Equatable {
    var id = UUID()
    let role: String
    let zh: String
    let en: String

    enum CodingKeys: String, CodingKey {
        case role
        case zh
        case en
    }
}

struct ExpressionCard: Identifiable, Codable, Equatable {
    var id = UUID()
    let phrase: String
    let meaning: String
    let example: String

    enum CodingKeys: String, CodingKey {
        case phrase
        case meaning
        case example
    }
}

struct DrillPrompt: Identifiable, Codable, Equatable {
    var id = UUID()
    let prompt: String
    let answer: String

    enum CodingKeys: String, CodingKey {
        case prompt
        case answer
    }
}

struct LearningResponse: Codable, Equatable {
    let summary: String
    let dialogue: [DialogueLine]
    let expressions: [ExpressionCard]
    let drills: [DrillPrompt]
}

struct TrainingStateResponse: Codable, Equatable {
    let sessionId: String
    let prompt: String
    let expectedAnswer: String
    let index: Int
    let total: Int
    let completed: Bool
    let feedback: String?
    let correction: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case prompt
        case expectedAnswer = "expected_answer"
        case index
        case total
        case completed
        case feedback
        case correction
    }
}

struct ScenarioRole: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let description: String
    let isUserCandidate: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case isUserCandidate = "is_user_candidate"
    }
}

struct SceneLine: Identifiable, Codable, Equatable {
    var id: Int { index }

    let index: Int
    let speaker: String
    let targetRole: String
    let sourceText: String
    let english: String
    let intent: String

    enum CodingKeys: String, CodingKey {
        case index
        case speaker
        case targetRole = "target_role"
        case sourceText = "source_text"
        case english
        case intent
    }
}

struct ScenarioResponse: Codable, Equatable {
    let sceneId: String
    let title: String
    let summary: String
    let roles: [ScenarioRole]
    let lines: [SceneLine]
    let expressions: [ExpressionCard]

    enum CodingKeys: String, CodingKey {
        case sceneId = "scene_id"
        case title
        case summary
        case roles
        case lines
        case expressions
    }
}

struct RoleplayMessage: Identifiable, Codable, Equatable {
    let id: String
    let speaker: String
    let role: String
    let content: String
    let translation: String?
    let feedback: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case speaker
        case role
        case content
        case translation
        case feedback
        case createdAt = "created_at"
    }
}

struct RoleplayStateResponse: Codable, Equatable {
    let sessionId: String
    let scenario: ScenarioResponse
    let selectedRole: String
    let aiRole: String
    let nextLine: SceneLine?
    let progress: Int
    let total: Int
    let score: Double
    let completed: Bool
    let messages: [RoleplayMessage]
    let latestFeedback: String?
    let latestAccepted: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case scenario
        case selectedRole = "selected_role"
        case aiRole = "ai_role"
        case nextLine = "next_line"
        case progress
        case total
        case score
        case completed
        case messages
        case latestFeedback = "latest_feedback"
        case latestAccepted = "latest_accepted"
    }
}

struct PracticeHistoryItem: Identifiable, Codable, Equatable {
    var id: String { sessionId }

    let sessionId: String
    let sceneId: String
    let title: String
    let selectedRole: String
    let status: String
    let turns: Int
    let total: Int
    let score: Double
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case sceneId = "scene_id"
        case title
        case selectedRole = "selected_role"
        case status
        case turns
        case total
        case score
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct PracticeHistoryResponse: Codable, Equatable {
    let items: [PracticeHistoryItem]
}

struct ScenarioSummary: Identifiable, Codable, Equatable {
    var id: String { sceneId }

    let sceneId: String
    let title: String
    let summary: String
    let roles: [ScenarioRole]
    let lineCount: Int
    let sourceStart: Date
    let sourceEnd: Date
    let createdAt: Date
    var lastScore: Int? = nil
    var lastPracticedAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case sceneId = "scene_id"
        case title
        case summary
        case roles
        case lineCount = "line_count"
        case sourceStart = "source_start"
        case sourceEnd = "source_end"
        case createdAt = "created_at"
        case lastScore = "last_score"
        case lastPracticedAt = "last_practiced_at"
    }
}

struct ScenarioListResponse: Codable, Equatable {
    let items: [ScenarioSummary]
    let generated: Bool
}
