import Foundation

struct AppUser: Codable, Equatable {
    let id: String
    let loginIdentifier: String
    let displayName: String?
    let avatarUrl: String?
    let plan: String
    let planTier: String?
    let planExpiresAt: Date?
    let balanceCents: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case loginIdentifier = "login_identifier"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case plan
        case planTier = "plan_tier"
        case planExpiresAt = "plan_expires_at"
        case balanceCents = "balance_cents"
        case createdAt = "created_at"
    }

    var effectiveTier: String { planTier ?? "free" }
    var tierName: String {
        switch effectiveTier {
        case "premium": return "高级会员"
        case "basic": return "基础会员"
        default: return "免费用户"
        }
    }
}

struct TokenUsageInfo: Codable, Equatable {
    let todayTokens: Int
    let dailyLimit: Int
    let remainingTokens: Int
    let overLimit: Bool
    // 月度费用额度（会员月费的 50%）。overLimit 现以「当月费用是否超额」为准。
    let overBudget: Bool
    // 客户端只展示百分比（不展示金额，避免「月费一半」的疑惑）；非会员=当日 token，会员=本周期费用
    let usagePercent: Double
    let isMember: Bool

    enum CodingKeys: String, CodingKey {
        case todayTokens = "today_tokens"
        case dailyLimit = "daily_limit"
        case remainingTokens = "remaining_tokens"
        case overLimit = "over_limit"
        case overBudget = "over_budget"
        case usagePercent = "usage_percent"
        case isMember = "is_member"
    }

    var usagePercentInt: Int { Int(usagePercent.rounded()) }
}

struct PlanItem: Identifiable, Codable, Equatable {
    let id: String
    let tier: String
    let months: Int
    let priceCents: Int
    let perMonthCents: Int
    let title: String

    enum CodingKeys: String, CodingKey {
        case id
        case tier
        case months
        case priceCents = "price_cents"
        case perMonthCents = "per_month_cents"
        case title
    }
}

struct PlanCatalogResponse: Codable, Equatable {
    let items: [PlanItem]
    let trialDays: Int

    enum CodingKeys: String, CodingKey {
        case items
        case trialDays = "trial_days"
    }
}

struct SubscribeRequest: Codable {
    let planId: String

    enum CodingKeys: String, CodingKey {
        case planId = "plan_id"
    }
}

struct AudioJob: Identifiable, Codable, Equatable {
    let id: String
    let filename: String
    let sizeBytes: Int
    let status: String
    let error: String?
    let sceneId: String?
    let transcriptChars: Int
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case filename
        case sizeBytes = "size_bytes"
        case status
        case error
        case sceneId = "scene_id"
        case transcriptChars = "transcript_chars"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var statusText: String {
        switch status {
        case "completed": return "已完成"
        case "failed": return "失败"
        case "pending": return "排队中"
        case "transcribing": return "转写中"
        case "generating": return "生成场景中"
        default: return status
        }
    }
}

struct AudioJobListResponse: Codable, Equatable {
    let items: [AudioJob]
}

struct AudioPrecheckResponse: Codable, Equatable {
    let duplicate: Bool
    let job: AudioJob?
}

struct AuthResponse: Codable {
    let token: String
    let refreshToken: String?
    let user: AppUser

    enum CodingKeys: String, CodingKey {
        case token
        case refreshToken = "refresh_token"
        case user
    }
}

struct AuthTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

struct TokenRefreshRequest: Codable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

struct ErrorResponse: Codable {
    let detail: String
}

struct AuthRequest: Codable {
    let email: String
    let password: String
}

struct EmailCodeRequest: Codable {
    let email: String
}

struct EmailCodeResponse: Codable {
    let sent: Bool
    let expiresInSeconds: Int
    let devCode: String?

    enum CodingKeys: String, CodingKey {
        case sent
        case expiresInSeconds = "expires_in_seconds"
        case devCode = "dev_code"
    }
}

struct EmailRegisterRequest: Codable {
    let email: String
    let password: String
    let code: String
}

struct WeChatLoginRequest: Codable {
    let code: String
    let nickname: String?
    let avatarUrl: String?
    let deviceId: String?

    enum CodingKeys: String, CodingKey {
        case code
        case nickname
        case avatarUrl = "avatar_url"
        case deviceId = "device_id"
    }
}

struct AIChatWireMessage: Codable, Equatable {
    let role: String
    let content: String
}

struct AIChatRequest: Codable {
    let message: String
    let messages: [AIChatWireMessage]
    let sceneId: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case message
        case messages
        case sceneId = "scene_id"
        case sessionId = "session_id"
    }
}

struct AIChatResponse: Codable, Equatable {
    let reply: String
}

struct TranscriptUploadItem: Codable {
    let id: UUID
    let timestamp: Date
    let text: String
}

struct TranscriptUploadRequest: Codable {
    let items: [TranscriptUploadItem]
}

struct TranscriptUploadResponse: Codable {
    let uploaded: Int
    let retentionDays: Int
    let generated: Int?
    let scenarioIds: [String]?

    enum CodingKeys: String, CodingKey {
        case uploaded
        case retentionDays = "retention_days"
        case generated
        case scenarioIds = "scenario_ids"
    }
}

struct CaptureUploadInitRequest: Codable {
    let start: Date?
    let end: Date?
    let estimatedItems: Int

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case estimatedItems = "estimated_items"
    }
}

struct CaptureUploadInitResponse: Codable {
    let uploadId: String
    let receivedChunks: [Int]
    let maxItemsPerChunk: Int

    enum CodingKeys: String, CodingKey {
        case uploadId = "upload_id"
        case receivedChunks = "received_chunks"
        case maxItemsPerChunk = "max_items_per_chunk"
    }
}

struct CaptureUploadChunkRequest: Codable {
    let uploadId: String
    let chunkIndex: Int
    let items: [TranscriptUploadItem]

    enum CodingKeys: String, CodingKey {
        case uploadId = "upload_id"
        case chunkIndex = "chunk_index"
        case items
    }
}

struct CaptureUploadChunkResponse: Codable {
    let uploadId: String
    let chunkIndex: Int
    let acceptedItems: Int
    let receivedChunks: [Int]

    enum CodingKeys: String, CodingKey {
        case uploadId = "upload_id"
        case chunkIndex = "chunk_index"
        case acceptedItems = "accepted_items"
        case receivedChunks = "received_chunks"
    }
}

struct CaptureUploadCompleteRequest: Codable {
    let uploadId: String
    let start: Date?
    let end: Date?

    enum CodingKeys: String, CodingKey {
        case uploadId = "upload_id"
        case start
        case end
    }
}

struct CaptureUploadCompleteResponse: Codable {
    let acceptedItems: Int
    let generated: Int
    let scenarioIds: [String]
    let scenarios: [ScenarioResponse]

    enum CodingKeys: String, CodingKey {
        case acceptedItems = "accepted_items"
        case generated
        case scenarioIds = "scenario_ids"
        case scenarios
    }
}

struct LearningGenerateRequest: Codable {
    let start: Date
    let end: Date
    let items: [TranscriptUploadItem]
}

struct TrainingStartRequest: Codable {
    let start: Date
    let end: Date
    let items: [TranscriptUploadItem]
}

struct ScenarioGenerateRequest: Codable {
    let start: Date
    let end: Date
    let items: [TranscriptUploadItem]
}

struct RoleplayStartRequest: Codable {
    let start: Date
    let end: Date
    let selectedRole: String
    let sceneId: String?
    let items: [TranscriptUploadItem]

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case selectedRole = "selected_role"
        case sceneId = "scene_id"
        case items
    }
}

struct RoleplayMessageRequest: Codable {
    let sessionId: String
    let message: String
    let guidanceMode: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case message
        case guidanceMode = "guidance_mode"
    }
}

struct RoleplayEvaluateRequest: Codable {
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
    }
}

struct TrainingAnswerRequest: Codable {
    let sessionId: String
    let answer: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case answer
    }
}

struct ApplePurchaseVerifyRequest: Codable {
    let productId: String
    let transactionId: String
    let originalTransactionId: String
    let jwsRepresentation: String?

    enum CodingKeys: String, CodingKey {
        case productId = "product_id"
        case transactionId = "transaction_id"
        case originalTransactionId = "original_transaction_id"
        case jwsRepresentation = "jws_representation"
    }
}

struct BillingResponse: Codable {
    let user: AppUser
    let verified: Bool
    let message: String
}

struct BillingLedgerItem: Identifiable, Codable, Equatable {
    let id: String
    let type: String
    let title: String
    let amountCents: Int
    let balanceAfterCents: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case amountCents = "amount_cents"
        case balanceAfterCents = "balance_after_cents"
        case createdAt = "created_at"
    }
}

struct NonmemberLimits: Codable, Equatable {
    let dailyChatTokens: Int
    let dailyCaptureTokens: Int
    let dailyCaptureSeconds: Int

    enum CodingKeys: String, CodingKey {
        case dailyChatTokens = "daily_chat_tokens"
        case dailyCaptureTokens = "daily_capture_tokens"
        case dailyCaptureSeconds = "daily_capture_seconds"
    }
}

struct BillingAccountResponse: Codable, Equatable {
    let user: AppUser
    let ledger: [BillingLedgerItem]
    let usage: TokenUsageInfo?
    let nonmemberLimits: NonmemberLimits?

    enum CodingKeys: String, CodingKey {
        case user, ledger, usage
        case nonmemberLimits = "nonmember_limits"
    }
}

struct RechargeCreateRequest: Codable {
    let amountCents: Int
    let method: String
    let planId: String?

    enum CodingKeys: String, CodingKey {
        case amountCents = "amount_cents"
        case method
        case planId = "plan_id"
    }
}

struct RechargeOrderResponse: Codable, Equatable {
    let orderId: String
    let method: String
    let amountCents: Int
    let status: String
    let paymentUrl: String?
    let qrCodeText: String?
    let qrCodeUrl: String?
    let receiverName: String?
    let receiverAccount: String?
    let message: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case orderId = "order_id"
        case method
        case amountCents = "amount_cents"
        case status
        case paymentUrl = "payment_url"
        case qrCodeText = "qr_code_text"
        case qrCodeUrl = "qr_code_url"
        case receiverName = "receiver_name"
        case receiverAccount = "receiver_account"
        case message
        case createdAt = "created_at"
    }
}

struct RechargeConfirmRequest: Codable {
    let orderId: String

    enum CodingKeys: String, CodingKey {
        case orderId = "order_id"
    }
}

struct CaptureQuotaResponse: Codable {
    let remainingTokens: Int
    let canCapture: Bool
    let approxSentences: Int
    let isMember: Bool
    let message: String

    enum CodingKeys: String, CodingKey {
        case remainingTokens = "remaining_tokens"
        case canCapture = "can_capture"
        case approxSentences = "approx_sentences"
        case isMember = "is_member"
        case message
    }
}

struct SupportTicketCreateRequest: Codable {
    let category: String
    let subject: String
    let body: String
}

struct SupportTicket: Identifiable, Codable, Equatable {
    let id: String
    let category: String
    let subject: String
    let body: String
    let status: String
    let adminReply: String?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, category, subject, body, status
        case adminReply = "admin_reply"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var statusText: String {
        switch status {
        case "open": return "待处理"
        case "processing": return "处理中"
        case "resolved": return "已解决"
        case "closed": return "已关闭"
        default: return status
        }
    }
}

struct SupportTicketListResponse: Codable, Equatable {
    let items: [SupportTicket]
}
