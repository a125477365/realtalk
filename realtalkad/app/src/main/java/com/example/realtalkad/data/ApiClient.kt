package com.example.realtalkad.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.time.Instant
import java.util.concurrent.TimeUnit

class ApiException(message: String) : Exception(message)

/**
 * RealTalk 后端客户端（与 iOS APIClient 等价）。
 * 默认地址在「设置」中可改，存于 AuthStore。
 */
class ApiClient(private val baseUrlProvider: () -> String) {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val jsonMedia = "application/json".toMediaType()
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(1800, TimeUnit.SECONDS)
        .build()

    /** 已登录请求收到 401（如账号被其它设备顶掉/令牌被吊销）时回调，用于自动退出登录。 */
    var onUnauthorized: (() -> Unit)? = null

    /** access 过期时回调：传入旧 access，用 refresh 续期并返回新 access；返回 null 表示续期失败。 */
    var onNeedsRefresh: (suspend (String?) -> String?)? = null

    private fun url(path: String) = baseUrlProvider().trimEnd('/') + path

    private suspend fun execute(request: Request, allowRefresh: Boolean = true): String = withContext(Dispatchers.IO) {
        val (code, body, successful) = client.newCall(request).execute().use { response ->
            Triple(response.code, response.body?.string().orEmpty(), response.isSuccessful)
        }
        if (code == 401) {
            // 仅对「已带登录凭证」的请求处理（登录/刷新请求本身的 401 不算）
            if (request.header("Authorization") != null) {
                // access 多半是过期：先用 refresh 续期并原样重试一次
                if (allowRefresh) {
                    val oldAccess = request.header("Authorization")?.removePrefix("Bearer ")?.trim()
                    val newToken = onNeedsRefresh?.invoke(oldAccess)
                    if (newToken != null) {
                        val retried = request.newBuilder().header("Authorization", "Bearer $newToken").build()
                        return@withContext execute(retried, allowRefresh = false)
                    }
                }
                onUnauthorized?.invoke()
            }
            val detail = runCatching { json.decodeFromString<ErrorResponse>(body).detail }
                .getOrDefault("请先登录")
            throw ApiException(detail)
        }
        if (!successful) {
            val detail = runCatching { json.decodeFromString<ErrorResponse>(body).detail }
                .getOrDefault("请求失败：HTTP $code")
            throw ApiException(detail)
        }
        body
    }

    private suspend inline fun <reified T> get(path: String, token: String? = null): T {
        val builder = Request.Builder().url(url(path)).get()
        token?.let { builder.header("Authorization", "Bearer $it") }
        return json.decodeFromString(execute(builder.build()))
    }

    private suspend inline fun <reified B, reified T> post(path: String, body: B, token: String? = null): T {
        val payload = json.encodeToString(body).toRequestBody(jsonMedia)
        val builder = Request.Builder().url(url(path)).post(payload)
        token?.let { builder.header("Authorization", "Bearer $it") }
        return json.decodeFromString(execute(builder.build()))
    }

    // ---- 认证 ----
    suspend fun wechatLogin(code: String, nickname: String?, deviceId: String? = null): AuthResponse =
        post("/auth/wechat/login", WeChatLoginRequest(code, nickname, deviceId = deviceId))

    suspend fun currentUser(token: String): AppUser = get("/auth/me", token)

    suspend fun refreshToken(refresh: String): AuthTokenResponse =
        post("/auth/token/refresh", TokenRefreshRequest(refresh))

    /** 服务端登出（注销全部设备/吊销令牌）。尽力而为，失败不影响本地清理。 */
    suspend fun serverLogout(token: String) {
        runCatching { post<EmptyBody, MessageResponse>("/auth/logout", EmptyBody(), token) }
    }

    // ---- 对话采集 ----
    suspend fun uploadTranscripts(items: List<TranscriptItem>, token: String): TranscriptUploadResponse =
        post("/transcript/upload", TranscriptUploadRequest(items), token)

    suspend fun uploadCaptureItems(items: List<TranscriptItem>, token: String, preferredChunkSize: Int = 80): CaptureUploadCompleteResponse {
        val sorted = items.sortedBy { it.timestamp }
        val start = sorted.firstOrNull()?.timestamp
        val end = sorted.lastOrNull()?.timestamp
        val init = post<CaptureUploadInitRequest, CaptureUploadInitResponse>(
            "/capture/upload/init",
            CaptureUploadInitRequest(start = start, end = end, estimatedItems = sorted.size),
            token,
        )
        val chunkSize = preferredChunkSize.coerceIn(1, init.maxItemsPerChunk.coerceAtLeast(1))
        sorted.chunked(chunkSize).forEachIndexed { index, chunk ->
            post<CaptureUploadChunkRequest, CaptureUploadChunkResponse>(
                "/capture/upload/chunk",
                CaptureUploadChunkRequest(init.uploadId, index, chunk),
                token,
            )
        }
        return post(
            "/capture/upload/complete",
            CaptureUploadCompleteRequest(init.uploadId, start, end),
            token,
        )
    }

    // ---- 场景 ----
    suspend fun todayScenarios(token: String): ScenarioListResponse = get("/scenario/today", token)
    suspend fun scenarioList(token: String): ScenarioListResponse = get("/scenario/list", token)
    suspend fun scenarioDetail(sceneId: String, token: String): Scenario = get("/scenario/$sceneId", token)

    // ---- 口语对练 ----
    suspend fun startRoleplay(sceneId: String, selectedRole: String, token: String): RoleplayState {
        val now = Instant.now().toString()
        return post("/roleplay/start", RoleplayStartRequest(now, now, selectedRole, sceneId), token)
    }

    suspend fun sendRoleplayMessage(sessionId: String, message: String, guidanceMode: String, token: String): RoleplayState =
        post("/roleplay/message", RoleplayMessageRequest(sessionId, message, guidanceMode), token)

    /** 按需最终评估：中途退出也能拿到评分与建议，不推进对话。 */
    suspend fun evaluateRoleplay(sessionId: String, token: String): RoleplayState =
        post("/roleplay/evaluate", RoleplayEvaluateRequest(sessionId), token)

    suspend fun aiChat(message: String, history: List<AIChatMessage>, sceneId: String?, sessionId: String?, token: String): AIChatResponse =
        post("/ai/chat", AIChatRequest(message, history, sceneId, sessionId), token)

    // ---- 账单 / 会员 ----
    suspend fun billingAccount(token: String): BillingAccount = get("/billing/account", token)
    suspend fun planCatalog(): PlanCatalog = get("/billing/plans")

    // ---- 客服工单 ----
    suspend fun createSupportTicket(category: String, subject: String, body: String, token: String): SupportTicket =
        post("/support/tickets", SupportTicketCreateRequest(category, subject, body), token)

    suspend fun mySupportTickets(token: String): SupportTicketListResponse = get("/support/tickets", token)
    suspend fun subscribe(planId: String, token: String): BillingAccount =
        post("/billing/subscribe", SubscribeRequest(planId), token)

    suspend fun createRecharge(amountCents: Int, method: String, token: String, planId: String? = null): RechargeOrder =
        post("/billing/recharge", RechargeCreateRequest(amountCents, method, planId), token)

    suspend fun confirmRecharge(orderId: String, token: String): BillingAccount =
        post("/billing/recharge/confirm", RechargeConfirmRequest(orderId), token)

    // ---- 高级会员音频上传 ----
    suspend fun audioJobs(token: String): AudioJobList = get("/audio/jobs", token)

    suspend fun uploadAudio(file: File, token: String): AudioJob {
        val mediaType = "audio/mpeg".toMediaType()
        val body: RequestBody = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("file", file.name, file.asRequestBody(mediaType))
            .build()
        val request = Request.Builder()
            .url(url("/audio/upload"))
            .header("Authorization", "Bearer $token")
            .post(body)
            .build()
        return json.decodeFromString(execute(request))
    }

    /** 断点续传：init → 分块 PUT（失败按服务端已收字节续传）→ complete。progress 回调 0f..1f。 */
    suspend fun uploadAudioResumable(
        file: File,
        token: String,
        onProgress: (Float) -> Unit = {},
    ): AudioJob = withContext(Dispatchers.IO) {
        val total = file.length()
        require(total > 0) { "文件为空" }
        val octet = "application/octet-stream".toMediaType()

        // 1) init
        val initBody = json.encodeToString(AudioUploadInitRequest(file.name, total)).toRequestBody(jsonMedia)
        val initReq = Request.Builder().url(url("/audio/upload/init"))
            .header("Authorization", "Bearer $token").post(initBody).build()
        val uploadId = json.decodeFromString<AudioUploadInitResponse>(execute(initReq)).uploadId

        // 2) 分块上传
        val chunk = ByteArray(4 * 1024 * 1024)
        var offset = 0L
        file.inputStream().use { input ->
            while (offset < total) {
                input.channel.position(offset)
                val read = input.read(chunk)
                if (read <= 0) break
                val slice = chunk.copyOf(read)
                var attempt = 0
                while (true) {
                    attempt++
                    try {
                        val put = Request.Builder()
                            .url(url("/audio/upload/chunk?upload_id=$uploadId&offset=$offset"))
                            .header("Authorization", "Bearer $token")
                            .put(slice.toRequestBody(octet))
                            .build()
                        client.newCall(put).execute().use { resp ->
                            if (resp.code == 409) {
                                offset = queryUploadOffset(uploadId, total, token)
                                throw ResumeSignal()
                            }
                            if (!resp.isSuccessful) throw ApiException("分块上传失败 HTTP ${resp.code}")
                        }
                        offset += read
                        onProgress(offset.toFloat() / total)
                        break
                    } catch (_: ResumeSignal) {
                        break // 已对齐 offset，外层重新定位
                    } catch (e: Exception) {
                        if (attempt >= 5) throw e
                        kotlinx.coroutines.delay(1000L * attempt)
                        offset = runCatching { queryUploadOffset(uploadId, total, token) }.getOrDefault(offset)
                    }
                }
            }
        }

        // 3) complete
        val name = java.net.URLEncoder.encode(file.name, "UTF-8")
        val completeReq = Request.Builder()
            .url(url("/audio/upload/complete?upload_id=$uploadId&filename=$name"))
            .header("Authorization", "Bearer $token")
            .post(ByteArray(0).toRequestBody(null))
            .build()
        json.decodeFromString(execute(completeReq))
    }

    private class ResumeSignal : Exception()

    private suspend fun queryUploadOffset(uploadId: String, total: Long, token: String): Long {
        val req = Request.Builder()
            .url(url("/audio/upload/status?upload_id=$uploadId&size_bytes=$total"))
            .header("Authorization", "Bearer $token").get().build()
        return json.decodeFromString<AudioUploadStatusResponse>(execute(req)).receivedBytes
    }
}
