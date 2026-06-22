package com.example.realtalkad.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/* 与 RealTalk 后端 API 一一对应的数据模型（与 iOS 端 APIModels/LearningModels 等价）。 */

@Serializable
data class AppUser(
    val id: String,
    @SerialName("login_identifier") val loginIdentifier: String,
    @SerialName("display_name") val displayName: String? = null,
    @SerialName("avatar_url") val avatarUrl: String? = null,
    val plan: String = "free",
    @SerialName("plan_tier") val planTier: String = "free",
    @SerialName("plan_expires_at") val planExpiresAt: String? = null,
    @SerialName("balance_cents") val balanceCents: Int = 0,
    @SerialName("created_at") val createdAt: String = "",
) {
    val tierName: String
        get() = when (planTier) {
            "premium" -> "高级会员"
            "basic" -> "基础会员"
            else -> "免费用户"
        }
}

@Serializable
data class AuthResponse(
    val token: String,
    @SerialName("refresh_token") val refreshToken: String? = null,
    val user: AppUser,
)

@Serializable
data class AuthTokenResponse(
    @SerialName("access_token") val accessToken: String,
    @SerialName("refresh_token") val refreshToken: String,
    @SerialName("expires_in") val expiresIn: Int = 0,
)

@Serializable
data class TokenRefreshRequest(@SerialName("refresh_token") val refreshToken: String)

@Serializable
data class MessageResponse(val message: String = "")

@Serializable
class EmptyBody

@Serializable
data class ErrorResponse(val detail: String = "请求失败")

@Serializable
data class TranscriptItem(val id: String, val timestamp: String, val text: String)

@Serializable
data class TranscriptUploadRequest(val items: List<TranscriptItem>)

@Serializable
data class TranscriptUploadResponse(
    val uploaded: Int,
    @SerialName("retention_days") val retentionDays: Int,
    val generated: Int = 0,
    @SerialName("scenario_ids") val scenarioIds: List<String> = emptyList(),
)

@Serializable
data class CaptureUploadInitRequest(
    val start: String? = null,
    val end: String? = null,
    @SerialName("estimated_items") val estimatedItems: Int = 0,
)

@Serializable
data class CaptureUploadInitResponse(
    @SerialName("upload_id") val uploadId: String,
    @SerialName("received_chunks") val receivedChunks: List<Int> = emptyList(),
    @SerialName("max_items_per_chunk") val maxItemsPerChunk: Int = 80,
)

@Serializable
data class CaptureUploadChunkRequest(
    @SerialName("upload_id") val uploadId: String,
    @SerialName("chunk_index") val chunkIndex: Int,
    val items: List<TranscriptItem> = emptyList(),
)

@Serializable
data class CaptureUploadChunkResponse(
    @SerialName("upload_id") val uploadId: String,
    @SerialName("chunk_index") val chunkIndex: Int,
    @SerialName("accepted_items") val acceptedItems: Int,
    @SerialName("received_chunks") val receivedChunks: List<Int> = emptyList(),
)

@Serializable
data class CaptureUploadCompleteRequest(
    @SerialName("upload_id") val uploadId: String,
    val start: String? = null,
    val end: String? = null,
)

@Serializable
data class CaptureUploadCompleteResponse(
    @SerialName("accepted_items") val acceptedItems: Int,
    val generated: Int,
    @SerialName("scenario_ids") val scenarioIds: List<String> = emptyList(),
    val scenarios: List<Scenario> = emptyList(),
)

@Serializable
data class ScenarioRole(
    val id: String,
    val name: String,
    val description: String = "",
    @SerialName("is_user_candidate") val isUserCandidate: Boolean = true,
)

@Serializable
data class SceneLine(
    val index: Int,
    val speaker: String,
    @SerialName("target_role") val targetRole: String,
    @SerialName("source_text") val sourceText: String,
    val english: String,
    val intent: String = "",
)

@Serializable
data class ExpressionCard(val phrase: String, val meaning: String, val example: String)

@Serializable
data class Scenario(
    @SerialName("scene_id") val sceneId: String,
    val title: String,
    val summary: String,
    val roles: List<ScenarioRole>,
    val lines: List<SceneLine>,
    val expressions: List<ExpressionCard> = emptyList(),
)

@Serializable
data class ScenarioSummary(
    @SerialName("scene_id") val sceneId: String,
    val title: String,
    val summary: String,
    val roles: List<ScenarioRole>,
    @SerialName("line_count") val lineCount: Int,
    @SerialName("source_start") val sourceStart: String,
    @SerialName("source_end") val sourceEnd: String,
    @SerialName("created_at") val createdAt: String,
    @SerialName("last_score") val lastScore: Int? = null,
    @SerialName("last_practiced_at") val lastPracticedAt: String? = null,
)

@Serializable
data class ScenarioListResponse(val items: List<ScenarioSummary>, val generated: Boolean = false)

@Serializable
data class RoleplayStartRequest(
    val start: String,
    val end: String,
    @SerialName("selected_role") val selectedRole: String,
    @SerialName("scene_id") val sceneId: String? = null,
    val items: List<TranscriptItem> = emptyList(),
)

@Serializable
data class RoleplayMessageRequest(
    @SerialName("session_id") val sessionId: String,
    val message: String,
    @SerialName("guidance_mode") val guidanceMode: String = "realtime",
)

@Serializable
data class RoleplayEvaluateRequest(
    @SerialName("session_id") val sessionId: String,
)

@Serializable
data class RoleplayMessage(
    val id: String,
    val speaker: String,
    val role: String,
    val content: String,
    val translation: String? = null,
    val feedback: String? = null,
    @SerialName("created_at") val createdAt: String,
)

@Serializable
data class RoleplayState(
    @SerialName("session_id") val sessionId: String,
    val scenario: Scenario,
    @SerialName("selected_role") val selectedRole: String,
    @SerialName("ai_role") val aiRole: String,
    @SerialName("next_line") val nextLine: SceneLine? = null,
    val progress: Int,
    val total: Int,
    val score: Double,
    val completed: Boolean,
    val messages: List<RoleplayMessage>,
    @SerialName("latest_feedback") val latestFeedback: String? = null,
    @SerialName("latest_accepted") val latestAccepted: Boolean? = null,
)

@Serializable
data class AIChatMessage(val role: String, val content: String)

@Serializable
data class AIChatRequest(
    val message: String,
    val messages: List<AIChatMessage> = emptyList(),
    @SerialName("scene_id") val sceneId: String? = null,
    @SerialName("session_id") val sessionId: String? = null,
)

@Serializable
data class AIChatResponse(val reply: String)

@Serializable
data class TokenUsageInfo(
    @SerialName("today_tokens") val todayTokens: Int,
    @SerialName("daily_limit") val dailyLimit: Int,
    @SerialName("remaining_tokens") val remainingTokens: Int,
    @SerialName("over_limit") val overLimit: Boolean,
    @SerialName("over_budget") val overBudget: Boolean = false,
    // 客户端只展示百分比（不暴露金额）；非会员=当日 token，会员=本周期费用
    @SerialName("usage_percent") val usagePercent: Double = 0.0,
    @SerialName("is_member") val isMember: Boolean = false,
)

@Serializable
data class CaptureQuota(
    @SerialName("remaining_tokens") val remainingTokens: Int,
    @SerialName("can_capture") val canCapture: Boolean,
    @SerialName("approx_sentences") val approxSentences: Int,
    @SerialName("is_member") val isMember: Boolean,
    val message: String = "",
)

@Serializable
data class SupportTicketCreateRequest(val category: String, val subject: String, val body: String)

@Serializable
data class SupportTicket(
    val id: String,
    val category: String,
    val subject: String,
    val body: String,
    val status: String,
    @SerialName("admin_reply") val adminReply: String? = null,
    @SerialName("created_at") val createdAt: String,
    @SerialName("updated_at") val updatedAt: String,
) {
    val statusText: String
        get() = when (status) {
            "open" -> "待处理"
            "processing" -> "处理中"
            "resolved" -> "已解决"
            "closed" -> "已关闭"
            else -> status
        }
}

@Serializable
data class SupportTicketListResponse(val items: List<SupportTicket> = emptyList())

@Serializable
data class LedgerItem(
    val id: String,
    val type: String,
    val title: String,
    @SerialName("amount_cents") val amountCents: Int,
    @SerialName("balance_after_cents") val balanceAfterCents: Int,
    @SerialName("created_at") val createdAt: String,
)

@Serializable
data class NonmemberLimits(
    @SerialName("daily_chat_tokens") val dailyChatTokens: Int = 1000,
    @SerialName("daily_capture_tokens") val dailyCaptureTokens: Int = 1000,
    @SerialName("daily_capture_seconds") val dailyCaptureSeconds: Int = 300,
)

@Serializable
data class BillingAccount(
    val user: AppUser,
    val ledger: List<LedgerItem> = emptyList(),
    val usage: TokenUsageInfo? = null,
    @SerialName("nonmember_limits") val nonmemberLimits: NonmemberLimits? = null,
)

@Serializable
data class PlanItem(
    val id: String,
    val tier: String,
    val months: Int,
    @SerialName("price_cents") val priceCents: Int,
    @SerialName("per_month_cents") val perMonthCents: Int,
    val title: String,
)

@Serializable
data class PlanCatalog(val items: List<PlanItem>, @SerialName("trial_days") val trialDays: Int = 30)

@Serializable
data class SubscribeRequest(@SerialName("plan_id") val planId: String)

// 通用场景（运维预置的全局场景，已含完整对话，可直接对练）
@Serializable
data class PresetSceneItem(
    @SerialName("scene_id") val sceneId: String,
    val title: String,
    @SerialName("line_count") val lineCount: Int,
    val roles: List<ScenarioRole> = emptyList(),
    @SerialName("last_score") val lastScore: Int? = null,
    @SerialName("last_practiced_at") val lastPracticedAt: String? = null,
)

@Serializable
data class PresetSceneGroup(val group: String, val scenes: List<PresetSceneItem> = emptyList())

@Serializable
data class PresetScenarioCatalog(val items: List<PresetSceneGroup> = emptyList())

@Serializable
data class RechargeCreateRequest(@SerialName("amount_cents") val amountCents: Int, val method: String, @SerialName("plan_id") val planId: String? = null)

@Serializable
data class RechargeOrder(
    @SerialName("order_id") val orderId: String,
    val method: String,
    @SerialName("amount_cents") val amountCents: Int,
    val status: String,
    @SerialName("payment_url") val paymentUrl: String? = null,
    @SerialName("qr_code_text") val qrCodeText: String? = null,
    @SerialName("qr_code_url") val qrCodeUrl: String? = null,
    @SerialName("receiver_name") val receiverName: String? = null,
    @SerialName("receiver_account") val receiverAccount: String? = null,
    val message: String,
    @SerialName("created_at") val createdAt: String,
)

@Serializable
data class RechargeConfirmRequest(@SerialName("order_id") val orderId: String)

@Serializable
data class AudioJob(
    val id: String,
    val filename: String,
    @SerialName("size_bytes") val sizeBytes: Long,
    val status: String,
    val error: String? = null,
    @SerialName("scene_id") val sceneId: String? = null,
    @SerialName("transcript_chars") val transcriptChars: Int = 0,
    @SerialName("created_at") val createdAt: String,
    @SerialName("updated_at") val updatedAt: String,
) {
    val statusText: String
        get() = when (status) {
            "completed" -> "已完成"
            "failed" -> "失败"
            "pending" -> "排队中"
            "transcribing" -> "转写中"
            "generating" -> "生成场景中"
            else -> status
        }
}

@Serializable
data class AudioJobList(val items: List<AudioJob>)

@Serializable
data class AudioPrecheck(val duplicate: Boolean, val job: AudioJob? = null)

@Serializable
data class AudioUploadInitRequest(val filename: String, @SerialName("size_bytes") val sizeBytes: Long)

@Serializable
data class AudioUploadInitResponse(@SerialName("upload_id") val uploadId: String, @SerialName("received_bytes") val receivedBytes: Long = 0)

@Serializable
data class AudioUploadStatusResponse(
    @SerialName("upload_id") val uploadId: String,
    @SerialName("received_bytes") val receivedBytes: Long,
    @SerialName("size_bytes") val sizeBytes: Long = 0,
    val completed: Boolean = false,
)

@Serializable
data class WeChatLoginRequest(
    val code: String,
    val nickname: String? = null,
    @SerialName("avatar_url") val avatarUrl: String? = null,
    @SerialName("device_id") val deviceId: String? = null,
)

/** 主界面聊天消息（本地 UI 模型） */
data class ChatMessage(
    val id: Long,
    val sender: Sender,
    val text: String,
) {
    enum class Sender { USER, ASSISTANT, SYSTEM }
}
