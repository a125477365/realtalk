package com.example.realtalkad.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
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
        .readTimeout(300, TimeUnit.SECONDS)   // 本地 CPU 合成/推理一句 60~110s，120s 偏紧
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
                .getOrDefault("请求没有完成，请稍后重试")
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

    /** 发送邮箱验证码（注册用）。dev 模式下 dev_code 直接返回，便于联调。 */
    suspend fun sendEmailCode(email: String): EmailCodeResponse =
        post("/auth/email/code", EmailCodeRequest(email))

    /** 邮箱 + 验证码注册 → 颁发令牌；随后调用方需拉 /auth/me 补全用户档案。 */
    suspend fun registerPassword(email: String, password: String, code: String): AuthTokenResponse =
        post("/auth/password/register", EmailRegisterRequest(email, password, code))

    /** 邮箱 + 密码登录 → 颁发令牌；同样只回令牌。 */
    suspend fun loginPassword(email: String, password: String, deviceId: String? = null): AuthTokenResponse =
        post("/auth/password/login", PasswordLoginRequest(email, password, deviceId))

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

    suspend fun captureQuota(token: String): CaptureQuota = get("/capture/quota", token)

    // ---- 场景 ----
    suspend fun todayScenarios(token: String): ScenarioListResponse = get("/scenario/today", token)
    suspend fun scenarioList(token: String): ScenarioListResponse = get("/scenario/list", token)

    // ---- 学习提醒（智能电话）：App 定时触发并上报信号，后端综合裁决（后端无任何主动动作）----
    suspend fun reminderCheck(request: ReminderCheckRequest, token: String): ReminderCheckResponse =
        post("/reminder/check", request, token)

    suspend fun reminderDismiss(sceneId: String, token: String) {
        post<ReminderDismissRequest, JsonObject>("/reminder/dismiss", ReminderDismissRequest(sceneId), token)
    }
    suspend fun scenarioDetail(sceneId: String, token: String): Scenario = get("/scenario/$sceneId", token)

    /** 删除用户自己的场景（预置通用场景不可删）。 */
    /** 清空全部私教/自由对话的历史记录。 */
    suspend fun clearFreetalkHistory(token: String) {
        val req = Request.Builder().url(url("/freetalk/history")).delete()
            .header("Authorization", "Bearer $token").build()
        execute(req)
    }

    suspend fun deleteScenario(sceneId: String, token: String) {
        val req = Request.Builder().url(url("/scenario/$sceneId")).delete()
            .header("Authorization", "Bearer $token").build()
        execute(req)
    }

    // ---- 通用场景（运维预置的全局场景，已含完整对话，可直接对练）----
    suspend fun presetCatalog(token: String): PresetScenarioCatalog = get("/scenario/presets/catalog", token)

    // ---- 口语对练 ----
    suspend fun startRoleplay(sceneId: String, selectedRole: String, token: String, resume: Boolean = false): RoleplayState {
        val now = Instant.now().toString()
        return post("/roleplay/start", RoleplayStartRequest(now, now, selectedRole, sceneId, resume = resume), token)
    }

    suspend fun sendRoleplayMessage(sessionId: String, message: String, guidanceMode: String, token: String): RoleplayState =
        post("/roleplay/message", RoleplayMessageRequest(sessionId, message, guidanceMode), token)

    /** 语境润色（详细指导浮层）：一句话 → 地道美式/商务正式/地道英式 三风格。 */
    suspend fun refine(text: String, token: String): RefineResponse =
        post("/practice/refine", RefineRequest(text), token)

    /** 字幕卡内「译」按钮的按需翻译：该条消息没带翻译时调用一次，结果缓存在字幕条上。 */
    suspend fun translate(text: String, token: String): String =
        post<TranslateRequest, TranslateResponse>("/practice/translate", TranslateRequest(text), token).text

    /** 方式1/2 后端语音：上传一句录音，后端识别+评分+发音纠正，返回对练状态。 */
    suspend fun sendRoleplayAudio(sessionId: String, guidanceMode: String, file: File, token: String): RoleplayState {
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("file", file.name, file.asRequestBody("audio/m4a".toMediaType()))
            .build()
        val req = Request.Builder()
            .url(url("/roleplay/message/audio?session_id=$sessionId&guidance_mode=$guidanceMode"))
            .header("Authorization", "Bearer $token")
            .post(body)
            .build()
        return json.decodeFromString(execute(req))
    }

    /** 后端 TTS 朗读一段文本（用用户选定音色），返回音频字节供播放。 */
    suspend fun ttsSpeak(text: String, token: String, cache: Boolean = true, tone: String = ""): ByteArray = withContext(Dispatchers.IO) {
        val q = java.net.URLEncoder.encode(text, "UTF-8")
        val toneQ = if (tone.isBlank()) "" else "&tone=" + java.net.URLEncoder.encode(tone, "UTF-8")
        val req = Request.Builder().url(url("/tts/speak?text=$q&cache=$cache$toneQ"))
            .header("Authorization", "Bearer $token").get().build()
        client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) throw ApiException("语音合成失败 HTTP ${resp.code}")
            resp.body?.bytes() ?: ByteArray(0)
        }
    }

    suspend fun ttsVoices(token: String): TtsVoices = get("/tts/voices", token)
    suspend fun setTtsVoice(voice: String, token: String): TtsVoices = post("/tts/voice", TtsVoiceBody(voice), token)

    /** 解码 WebSocket 推来的整轮对练状态（与 HTTP 同一套解码器）。 */
    fun decodeRoleplayState(jsonStr: String): RoleplayState? =
        runCatching { json.decodeFromString<RoleplayState>(jsonStr) }.getOrNull()

    /** 沉浸式后端语音流的 WebSocket 地址（http→ws / https→wss）。 */
    fun roleplayStreamUrl(sessionId: String, token: String): String {
        val q = java.net.URLEncoder.encode(token, "UTF-8")
        val base = url("/roleplay/stream?token=$q&session_id=$sessionId")
        return when {
            base.startsWith("https://") -> "wss://" + base.removePrefix("https://")
            base.startsWith("http://") -> "ws://" + base.removePrefix("http://")
            else -> base
        }
    }

    /** 自由对话（一对一语音老师）流地址；协议同沉浸式流。
     *  mode: chat=对话（默认）/ translate=实时翻译；sceneId 非空 = 带场景剧本进场（自由发挥式场景对话）。 */
    /** 实时翻译·流式（边说边出）：连续上行，服务端只转写通道自动分句，逐句回原文/译文/译文语音。 */
    fun translateStreamUrl(token: String): String {
        val q = java.net.URLEncoder.encode(token, "UTF-8")
        val base = url("/translate/stream?token=$q")
        return when {
            base.startsWith("https://") -> "wss://" + base.removePrefix("https://")
            base.startsWith("http://") -> "ws://" + base.removePrefix("http://")
            else -> base
        }
    }

    fun freeTalkStreamUrl(token: String, mode: String = "chat", sceneId: String = "", live: Boolean = false): String {
        val q = java.net.URLEncoder.encode(token, "UTF-8")
        val scenePart = if (sceneId.isBlank()) "" else "&scene_id=" + java.net.URLEncoder.encode(sceneId, "UTF-8")
        val livePart = if (live) "&live=1" else ""
        val base = url("/freetalk/stream?token=$q&mode=$mode$scenePart$livePart")
        return when {
            base.startsWith("https://") -> "wss://" + base.removePrefix("https://")
            base.startsWith("http://") -> "ws://" + base.removePrefix("http://")
            else -> base
        }
    }

    /** 按需最终评估：中途退出也能拿到评分与建议，不推进对话。 */
    suspend fun evaluateRoleplay(sessionId: String, token: String): RoleplayState =
        post("/roleplay/evaluate", RoleplayEvaluateRequest(sessionId), token)

    suspend fun aiChat(message: String, history: List<AIChatMessage>, sceneId: String?, sessionId: String?, token: String): AIChatResponse =
        post("/ai/chat", AIChatRequest(message, history, sceneId, sessionId), token)

    // ---- 账单 / 会员 ----
    suspend fun billingAccount(token: String): BillingAccount = get("/billing/account", token)
    suspend fun planCatalog(): PlanCatalog = get("/billing/plans")

    // ---- 客服工单 ----
    suspend fun createSupportTicket(category: String, subject: String, body: String, images: List<String>, token: String): SupportTicket =
        post("/support/tickets", SupportTicketCreateRequest(category, subject, body, images), token)

    suspend fun mySupportTickets(token: String): SupportTicketListResponse = get("/support/tickets", token)
    suspend fun subscribe(planId: String, token: String): BillingAccount =
        post("/billing/subscribe", SubscribeRequest(planId), token)

    suspend fun createRecharge(amountCents: Int, method: String, token: String, planId: String? = null): RechargeOrder =
        post("/billing/recharge", RechargeCreateRequest(amountCents, method, planId), token)

    suspend fun confirmRecharge(orderId: String, token: String): BillingAccount =
        post("/billing/recharge/confirm", RechargeConfirmRequest(orderId), token)

    /** 闲鱼卡密兑换：12 位数字码，立即开通会员/加余额。 */
    suspend fun redeemCode(code: String, token: String): BillingAccount =
        post("/billing/redeem", RedeemCodeRequest(code), token)

    // ---- 高级会员音频上传 ----
    suspend fun audioJobs(token: String): AudioJobList = get("/audio/jobs", token)

    /** 断点续传：init → 分块 PUT（每个报文带文件 MD5，失败按服务端已收字节续传）→ complete。
     *  服务端按 MD5 把文件路由到对应语音服务器。返回 true=服务端已有同文件（秒回成功，无需重传）。 */
    suspend fun uploadAudioResumable(
        file: File,
        token: String,
        onProgress: (Float) -> Unit = {},
    ): Boolean = withContext(Dispatchers.IO) {
        val total = file.length()
        require(total > 0) { "文件为空" }
        val octet = "application/octet-stream".toMediaType()
        val md5 = fileMd5(file)

        // 1) init（带 md5）。done=true → 服务端已有同文件，直接成功。
        val initBody = json.encodeToString(AudioUploadInitRequest(file.name, total, md5)).toRequestBody(jsonMedia)
        val initReq = Request.Builder().url(url("/audio/upload/init"))
            .header("Authorization", "Bearer $token").post(initBody).build()
        val init = json.decodeFromString<AudioUploadInitResponse>(execute(initReq))
        if (init.done) {
            onProgress(1f)
            return@withContext true
        }

        // 2) 分块上传（从服务端已收字节处续传）
        val chunk = ByteArray(4 * 1024 * 1024)
        var offset = init.receivedBytes.coerceIn(0, total)
        onProgress(offset.toFloat() / total)
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
                            .url(url("/audio/upload/chunk?md5=$md5&offset=$offset"))
                            .header("Authorization", "Bearer $token")
                            .put(slice.toRequestBody(octet))
                            .build()
                        client.newCall(put).execute().use { resp ->
                            if (resp.code == 409) {
                                offset = queryUploadOffset(md5, total, token)
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
                        offset = runCatching { queryUploadOffset(md5, total, token) }.getOrDefault(offset)
                    }
                }
            }
        }

        // 3) complete（带 md5 + size_bytes，服务端校验完整性并打 .ready 标记）
        val name = java.net.URLEncoder.encode(file.name, "UTF-8")
        val completeReq = Request.Builder()
            .url(url("/audio/upload/complete?md5=$md5&filename=$name&size_bytes=$total"))
            .header("Authorization", "Bearer $token")
            .post(ByteArray(0).toRequestBody(null))
            .build()
        execute(completeReq) // 应答只需 2xx
        false
    }

    private class ResumeSignal : Exception()

    private suspend fun queryUploadOffset(md5: String, total: Long, token: String): Long {
        val req = Request.Builder()
            .url(url("/audio/upload/status?md5=$md5&size_bytes=$total"))
            .header("Authorization", "Bearer $token").get().build()
        return json.decodeFromString<AudioUploadStatusResponse>(execute(req)).receivedBytes
    }

    /** 流式计算文件 MD5（与服务端命名/路由一致）。 */
    private fun fileMd5(file: File): String {
        val md = java.security.MessageDigest.getInstance("MD5")
        file.inputStream().use { input ->
            val buf = ByteArray(1024 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}
