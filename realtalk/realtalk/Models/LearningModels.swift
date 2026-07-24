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

struct PronunciationWord: Codable, Equatable {
    let word: String
    let ok: Bool
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
    let recognizedText: String?              // 后端语音识别到的英文（语音回合）
    let pronunciation: [PronunciationWord]   // 逐词发音命中（语音回合）
    let latestScores: [String: Int]?         // 本轮四维评分：发音/语法/自然度/词汇(0-100)

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
        case recognizedText = "recognized_text"
        case pronunciation
        case latestScores = "latest_scores"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        scenario = try c.decode(ScenarioResponse.self, forKey: .scenario)
        selectedRole = try c.decode(String.self, forKey: .selectedRole)
        aiRole = try c.decode(String.self, forKey: .aiRole)
        nextLine = try c.decodeIfPresent(SceneLine.self, forKey: .nextLine)
        progress = try c.decode(Int.self, forKey: .progress)
        total = try c.decode(Int.self, forKey: .total)
        score = try c.decode(Double.self, forKey: .score)
        completed = try c.decode(Bool.self, forKey: .completed)
        messages = try c.decode([RoleplayMessage].self, forKey: .messages)
        latestFeedback = try c.decodeIfPresent(String.self, forKey: .latestFeedback)
        latestAccepted = try c.decodeIfPresent(Bool.self, forKey: .latestAccepted)
        recognizedText = try c.decodeIfPresent(String.self, forKey: .recognizedText)
        pronunciation = (try c.decodeIfPresent([PronunciationWord].self, forKey: .pronunciation)) ?? []
        latestScores = try c.decodeIfPresent([String: Int].self, forKey: .latestScores)
    }
}

// ---- 训练系统：今日训练路径（课程编排引擎的产物）----
struct TrainingSceneItem: Identifiable, Codable, Equatable {
    var id: String { sceneId }
    let sceneId: String
    let title: String
    let summary: String
    let status: String            // new / review / mastered
    let attempts: Int
    let scores: [String: Int]     // 发音/语法/自然度/词汇 最近一次(0-100)
    let reason: String

    enum CodingKeys: String, CodingKey {
        case sceneId = "scene_id"
        case title, summary, status, attempts, scores, reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sceneId = try c.decode(String.self, forKey: .sceneId)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        status = try c.decode(String.self, forKey: .status)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        scores = try c.decodeIfPresent([String: Int].self, forKey: .scores) ?? [:]
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

struct TrainingTodayResponse: Codable, Equatable {
    let date: String
    let scenes: [TrainingSceneItem]
    let reviewsDue: Int
    let masteredTotal: Int
    let minutesEstimate: Int

    enum CodingKeys: String, CodingKey {
        case date, scenes
        case reviewsDue = "reviews_due"
        case masteredTotal = "mastered_total"
        case minutesEstimate = "minutes_estimate"
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
    var inProgress: Bool = false          // 有未完成对练可继续
    var resumeSessionId: String? = nil    // 可继续的会话 id
    var resumeProgress: Int = 0           // 已练用户句数

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
        case inProgress = "in_progress"
        case resumeSessionId = "resume_session_id"
        case resumeProgress = "resume_progress"
    }

    // 自定义构造保留（供代码内构造场景卡）；新字段带默认值，老响应缺字段也能解码。
    init(sceneId: String, title: String, summary: String, roles: [ScenarioRole], lineCount: Int,
         sourceStart: Date, sourceEnd: Date, createdAt: Date, lastScore: Int? = nil,
         lastPracticedAt: Date? = nil, inProgress: Bool = false, resumeSessionId: String? = nil,
         resumeProgress: Int = 0) {
        self.sceneId = sceneId; self.title = title; self.summary = summary; self.roles = roles
        self.lineCount = lineCount; self.sourceStart = sourceStart; self.sourceEnd = sourceEnd
        self.createdAt = createdAt; self.lastScore = lastScore; self.lastPracticedAt = lastPracticedAt
        self.inProgress = inProgress; self.resumeSessionId = resumeSessionId; self.resumeProgress = resumeProgress
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sceneId = try c.decode(String.self, forKey: .sceneId)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        roles = try c.decode([ScenarioRole].self, forKey: .roles)
        lineCount = try c.decode(Int.self, forKey: .lineCount)
        sourceStart = try c.decode(Date.self, forKey: .sourceStart)
        sourceEnd = try c.decode(Date.self, forKey: .sourceEnd)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastScore = try c.decodeIfPresent(Int.self, forKey: .lastScore)
        lastPracticedAt = try c.decodeIfPresent(Date.self, forKey: .lastPracticedAt)
        inProgress = try c.decodeIfPresent(Bool.self, forKey: .inProgress) ?? false
        resumeSessionId = try c.decodeIfPresent(String.self, forKey: .resumeSessionId)
        resumeProgress = try c.decodeIfPresent(Int.self, forKey: .resumeProgress) ?? 0
    }
}

struct ScenarioListResponse: Codable, Equatable {
    let items: [ScenarioSummary]
    let generated: Bool
}
