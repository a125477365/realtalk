package com.example.realtalkad

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.realtalkad.data.ApiClient
import com.example.realtalkad.data.AppUser
import com.example.realtalkad.data.AudioJob
import com.example.realtalkad.data.AuthStore
import com.example.realtalkad.data.BillingAccount
import com.example.realtalkad.data.ChatMessage
import com.example.realtalkad.data.PlanItem
import com.example.realtalkad.data.RechargeOrder
import com.example.realtalkad.data.RoleplayState
import com.example.realtalkad.data.Scenario
import com.example.realtalkad.data.ScenarioSummary
import com.example.realtalkad.data.TranscriptFileStore
import com.example.realtalkad.data.TranscriptItem
import com.example.realtalkad.speech.PracticeSpeech
import com.example.realtalkad.speech.RealtimeVoiceClient
import com.example.realtalkad.speech.SpeechCapture
import com.example.realtalkad.speech.VoicePlayer
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant
import java.time.LocalTime
import java.util.UUID

/** 与 iOS AppModel 等价的业务编排层。 */
class AppViewModel(application: Application) : AndroidViewModel(application) {

    val auth = AuthStore(application)
    val api = ApiClient { auth.baseUrl }
    val capture = SpeechCapture(application)
    val practice = PracticeSpeech(application)
    val voice = VoicePlayer(application)
    val realtime = RealtimeVoiceClient(application)
    private val transcriptStore = TranscriptFileStore(application)

    val user = MutableStateFlow<AppUser?>(null)
    val billing = MutableStateFlow<BillingAccount?>(null)
    val plans = MutableStateFlow<List<PlanItem>>(emptyList())
    val todayScenarios = MutableStateFlow<List<ScenarioSummary>>(emptyList())
    val partialSubtitle = MutableStateFlow("")
    val practiceAudioLevel = MutableStateFlow(0f)
    val aiAudioLevel = MutableStateFlow(0f)
    val isRecording = MutableStateFlow(false)
    val isListening = MutableStateFlow(false)
    val isSpeaking = MutableStateFlow(false)
    val isWorking = MutableStateFlow(false)
    val isVoiceActive = MutableStateFlow(false)
    val statusMessage = MutableStateFlow("")
    val rechargeOrder = MutableStateFlow<RechargeOrder?>(null)
    val audioJobs = MutableStateFlow<List<AudioJob>>(emptyList())
    val isUploadingAudio = MutableStateFlow(false)
    val showSubtitles = MutableStateFlow(auth.showSubtitles)
    val guidanceMode = MutableStateFlow("realtime")            // 当前会话生效（不可中途切）
    val conversationMode = MutableStateFlow("immersive")       // 当前会话生效
    val guidancePreference = MutableStateFlow(auth.guidancePreference)     // ask/realtime/final
    val conversationPreference = MutableStateFlow(auth.conversationPreference) // ask/voice/immersive/manual
    val pendingPractice = MutableStateFlow<Pair<ScenarioSummary, String>?>(null) // 非空时弹「对话前询问」
    val showVoiceLLM = MutableStateFlow(false)                          // 控制实时语音沉浸式界面呈现
    val fontScale = MutableStateFlow(auth.fontScale)
    val autoSpeakAI = MutableStateFlow(auth.autoSpeakAI)
    val continuousVoice = MutableStateFlow(auth.continuousVoice)
    val autoCaptureEnabled = MutableStateFlow(auth.autoCaptureEnabled)
    // 多个自动采集时段（"HH:mm" 起止对）
    val captureWindows = MutableStateFlow(parseCaptureWindows(auth.captureWindows))
    val appearance = MutableStateFlow(auth.appearance)   // system/light/dark
    val myTickets = MutableStateFlow<List<com.example.realtalkad.data.SupportTicket>>(emptyList())
    val roleplayState = MutableStateFlow<RoleplayState?>(null)
    val showImmersive = MutableStateFlow(false)
    val presetCatalog = MutableStateFlow<List<com.example.realtalkad.data.PresetScenarioGroup>>(emptyList()) // 通用场景目录
    val isGeneratingPreset = MutableStateFlow(false)
    val generatingSubId = MutableStateFlow<String?>(null)

    private var scenario: Scenario? = null
    private var roleplay: RoleplayState? = null
    private var selectedRole = ""
    private val spokenMessageIds = mutableSetOf<String>()
    private var answerTimeoutJob: Job? = null
    private var captureScheduleJob: Job? = null
    private var autoCaptureRunning = false
    // 用户在某采集时段内手动停止后，抑制自动重启直到该时段结束
    private var autoCaptureSuppressedUntil: LocalTime? = null
    // 本次采集开始时的剩余额度(token)与起始字符数，用于采集中定时预估、超额自动停止
    private var captureRemainingTokens: Int? = null
    private var captureBaselineChars = 0
    // 上次重试上传待同步内容的时间（每小时重试一次直到成功；后端按内容哈希幂等去重）
    private var lastUploadRetryAt = 0L
    // 非会员每日采集时长本地计时（后端看不到采集过程，只能 app 控制）
    private var captureStartedAt = 0L
    private val refreshMutex = Mutex()

    val isAuthenticated: StateFlow<AppUser?> get() = user

    init {
        capture.onSegment = { text ->
            transcriptStore.add(TranscriptItem(UUID.randomUUID().toString(), Instant.now().toString(), text))
        }
        capture.onStateChange = { isRecording.value = it }
        practice.onPartial = { partialSubtitle.value = it }
        practice.onLevel = { practiceAudioLevel.value = it }
        practice.onStateChange = { isListening.value = it }
        practice.onUtterance = { text -> viewModelScope.launch { submitUtterance(text) } }
        voice.onStateChange = { isSpeaking.value = it }
        voice.onLevel = { aiAudioLevel.value = it }
        // 账号被其它设备顶掉/令牌被吊销时服务端返回 401 → 自动退出回到登录页
        api.onUnauthorized = { viewModelScope.launch { forceLogout() } }
        // access 过期时用 refresh 续期（单飞）
        api.onNeedsRefresh = { oldAccess -> refreshAccessToken(oldAccess) }

        appendChat(ChatMessage.Sender.ASSISTANT, "今天想练哪段真实对话？选上方场景，或用底部按钮采集。")
        bootstrap()
        startCaptureScheduleLoop()
    }

    fun bootstrap() {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            runCatching { api.currentUser(token) }
                .onSuccess { user.value = it }
                .onFailure { auth.clear(); user.value = null; return@launch }
            refreshBilling()
            loadTodayScenarios()
            loadPlans()
        }
    }

    // ---- 登录 ----

    fun loginWithWeChat() {
        viewModelScope.launch {
            isWorking.value = true
            runCatching {
                val ctx = getApplication<Application>()
                if (com.example.realtalkad.wechat.WeChatAuth.isAvailable(ctx)) {
                    // 真实微信一键登录：拉起微信授权拿 code，交后端用移动应用凭据换 openid
                    statusMessage.value = "正在打开微信…"
                    val code = com.example.realtalkad.wechat.WeChatAuth.authorize(ctx)
                    api.wechatLogin(code, null, auth.deviceId)
                } else {
                    // 未配置 AppID 或未装微信：开发模拟登录
                    api.wechatLogin(auth.devWeChatCode, "微信用户", auth.deviceId)
                }
            }
                .onSuccess {
                    auth.token = it.token
                    auth.refreshToken = it.refreshToken
                    user.value = it.user
                    statusMessage.value = "登录成功"
                    refreshBilling(); loadTodayScenarios(); loadPlans()
                }
                .onFailure { statusMessage.value = it.message ?: "登录失败" }
            isWorking.value = false
        }
    }

    fun logout() {
        val token = auth.token
        if (token != null) viewModelScope.launch { api.serverLogout(token) }  // 尽力注销服务端会话
        auth.clear()
        user.value = null
        billing.value = null
        statusMessage.value = "已退出登录"
    }

    /** access 过期：用 refresh 令牌换新 access；并发调用合并为一次刷新，失败则强制登出。 */
    private suspend fun refreshAccessToken(oldAccess: String?): String? = refreshMutex.withLock {
        val current = auth.token
        if (current != null && current != oldAccess) return@withLock current  // 已被别的请求刷新过
        val refresh = auth.refreshToken ?: return@withLock null
        runCatching { api.refreshToken(refresh) }.fold(
            onSuccess = {
                auth.token = it.accessToken
                auth.refreshToken = it.refreshToken
                it.accessToken
            },
            onFailure = {
                viewModelScope.launch { forceLogout() }
                null
            },
        )
    }

    /** 账号被其它设备顶掉/令牌吊销：自动退出并回到登录页，需重新授权。 */
    private fun forceLogout() {
        if (auth.token == null && user.value == null) return
        auth.clear()
        isVoiceActive.value = false
        showImmersive.value = false
        showVoiceLLM.value = false
        runCatching { realtime.cancel() }
        runCatching { practice.stop() }
        runCatching { voice.stop() }
        if (capture.isRecording) runCatching { capture.stop() }
        user.value = null
        billing.value = null
        statusMessage.value = "账号已在其他设备登录，请重新授权登录"
    }

    // ---- 采集 ----

    fun toggleRecording() {
        if (capture.isRecording) stopCapture() else startCapture()
    }

    /** 供 Siri/Google 助手语音指令与主界面按钮共用：开始采集（先校验额度）。 */
    fun startCapture() {
        if (capture.isRecording) return
        autoCaptureRunning = false
        viewModelScope.launch { startCaptureWithQuotaCheck("正在采集真实对话") }
    }

    private fun pendingCharCount(): Int = transcriptStore.pending().sumOf { it.text.length }

    // ---- 非会员每日采集时长限额（客户端本地强制） ----

    private fun isNonMember(): Boolean = user.value?.planTier == "free"
    private fun nonmemberCaptureSecondsLimit(): Int = billing.value?.nonmemberLimits?.dailyCaptureSeconds ?: 300
    private fun today(): String = java.time.LocalDate.now().toString()

    private fun capturedSecondsToday(): Int =
        if (auth.captureSecondsDay == today()) auth.captureSecondsValue else 0

    private fun addCapturedSeconds(seconds: Int) {
        if (seconds <= 0) return
        val base = capturedSecondsToday()
        auth.captureSecondsDay = today()
        auth.captureSecondsValue = base + seconds
    }

    /** 停止采集时把本次时长累计进今日计数。 */
    private fun commitCaptureSeconds() {
        if (captureStartedAt != 0L) {
            addCapturedSeconds(((System.currentTimeMillis() - captureStartedAt) / 1000L).toInt())
        }
        captureStartedAt = 0L
    }

    /** 采集中定时检查：非会员今日采集时长超限则自动停止并提交。 */
    private fun enforceCaptureSecondsLimit() {
        if (!capture.isRecording || !isNonMember()) return
        val limit = nonmemberCaptureSecondsLimit()
        if (limit <= 0) return
        val elapsed = if (captureStartedAt != 0L) ((System.currentTimeMillis() - captureStartedAt) / 1000L).toInt() else 0
        if (capturedSecondsToday() + elapsed < limit) return
        commitCaptureSeconds()
        captureRemainingTokens = null
        capture.stop()
        autoCaptureRunning = false
        statusMessage.value = "今日免费采集时长已用完，已停止并提交；升级会员可不限时长"
        uploadPendingAndRefresh()
    }

    /** 开始采集前查询剩余额度：超额拦截、不足提示但允许；记录额度用于采集中自动停止。 */
    private suspend fun startCaptureWithQuotaCheck(okMessage: String) {
        captureRemainingTokens = null
        // 非会员每日采集时长限额（客户端本地强制）
        if (isNonMember() && nonmemberCaptureSecondsLimit() > 0 && capturedSecondsToday() >= nonmemberCaptureSecondsLimit()) {
            statusMessage.value = "今日免费采集时长已用完，升级会员可不限时长，或明天再来"
            return
        }
        val token = auth.token
        val quota = if (token != null) runCatching { api.captureQuota(token) }.getOrNull() else null
        if (quota != null) {
            if (!quota.canCapture) { statusMessage.value = quota.message; return }
            captureRemainingTokens = quota.remainingTokens
            captureBaselineChars = pendingCharCount()
            capture.start()
            captureStartedAt = System.currentTimeMillis()
            statusMessage.value = if (quota.message.isBlank()) okMessage else quota.message
        } else {
            capture.start()
            captureStartedAt = System.currentTimeMillis()
            statusMessage.value = okMessage
        }
    }

    /** 每小时重试一次未成功上传的待同步内容，直到成功（后端按内容哈希幂等，不生成重复场景）。 */
    private fun retryPendingUploadsIfNeeded() {
        if (capture.isRecording || auth.token == null) return
        if (transcriptStore.pending().isEmpty()) return
        val now = System.currentTimeMillis()
        if (lastUploadRetryAt != 0L && now - lastUploadRetryAt < 3_600_000L) return
        lastUploadRetryAt = now
        uploadPendingAndRefresh()
    }

    /** 采集中定时预估：已采集字符数超过开始时的剩余额度则自动停止并提交。 */
    private fun enforceCaptureQuotaDuringRecording() {
        if (!capture.isRecording) return
        val remaining = captureRemainingTokens ?: return
        val collected = (pendingCharCount() - captureBaselineChars).coerceAtLeast(0)
        if (collected >= remaining) {
            captureRemainingTokens = null
            commitCaptureSeconds()
            capture.stop()
            autoCaptureRunning = false
            statusMessage.value = "已达当月额度，已自动停止采集并提交生成场景"
            uploadPendingAndRefresh()
        }
    }

    /** 供语音指令与主界面按钮共用：停止采集并推送生成场景。 */
    fun stopCapture() {
        if (!capture.isRecording) return
        // 若在自动采集时段内手动停止：抑制本时段的自动重启
        if (autoCaptureEnabled.value) currentAutoWindowEnd()?.let { autoCaptureSuppressedUntil = it }
        captureRemainingTokens = null
        commitCaptureSeconds()
        capture.stop()
        autoCaptureRunning = false
        statusMessage.value = "已停止采集，正在发送给后台并生成场景…"
        uploadPendingAndRefresh()
    }

    private fun uploadPendingAndRefresh() {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            kotlinx.coroutines.delay(400) // 等最后的识别结果落入队列
            val items = transcriptStore.pending()
            if (items.isEmpty()) {
                statusMessage.value = "没采到声音"
                return@launch
            }
            statusMessage.value = "已发布给后台，正在生成场景…（${items.size} 句）"
            runCatching { api.uploadCaptureItems(items, token) }
                .onSuccess {
                    transcriptStore.remove(items.map { item -> item.id }.toSet())
                    statusMessage.value = "已生成 ${it.generated} 个场景，可在列表中选择练习"
                    loadTodayScenarios()
                }
                .onFailure { statusMessage.value = "上传失败：${it.message ?: ""}" }
        }
    }

    /** 文字录入真实对话（模拟器无麦克风时的回退路径）。 */
    fun ingestTypedConversation(raw: String) {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            val body = raw.removePrefix("录入对话").removePrefix("录入").trim(' ', '：', ':', '\n')
            if (body.isEmpty()) {
                appendChat(ChatMessage.Sender.ASSISTANT, "发：录入对话 + 今天说过的话。")
                return@launch
            }
            val sentences = body.split('。', '！', '？', '!', '?', '；', ';', '\n')
                .map { it.trim() }.filter { it.isNotEmpty() }
                .ifEmpty { listOf(body) }
            val now = Instant.now()
            val items = sentences.mapIndexed { i, s ->
                TranscriptItem(UUID.randomUUID().toString(), now.plusSeconds(i.toLong()).toString(), s)
            }
            runCatching { api.uploadCaptureItems(items, token) }
                .onSuccess {
                    statusMessage.value = "已录入 ${it.acceptedItems} 句，生成 ${it.generated} 个场景"
                    loadTodayScenarios()
                }
                .onFailure { appendChat(ChatMessage.Sender.ASSISTANT, "录入失败：${it.message ?: ""}") }
        }
    }

    // ---- 场景与对练 ----

    fun loadTodayScenarios() {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            runCatching { api.todayScenarios(token) }
                .onSuccess {
                    todayScenarios.value = it.items
                    if (it.generated) appendChat(ChatMessage.Sender.ASSISTANT, "今日场景已生成，点卡片开练。")
                }
                .onFailure { statusMessage.value = it.message ?: "" }
        }
    }

    fun loadScenarioList() {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            runCatching { api.scenarioList(token) }
                .onSuccess { todayScenarios.value = it.items }
                .onFailure { statusMessage.value = it.message ?: "" }
        }
    }

    /** 加载通用场景目录（主场景 → 子场景标题），供没有录音时直接选场景练口语。 */
    fun loadPresetCatalog() {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            runCatching { api.presetCatalog(token) }
                .onSuccess { presetCatalog.value = it.items }
                .onFailure { statusMessage.value = it.message ?: "" }
        }
    }

    /** 选中某个通用子场景：让后端调用 AI 即时生成约 40 句中英对话并落库，成功后回调可对练的场景摘要。 */
    fun generatePresetScenario(groupId: String, subId: String, onReady: (ScenarioSummary) -> Unit) {
        if (auth.token == null) { statusMessage.value = "请先登录"; return }
        if (isGeneratingPreset.value) return
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            isGeneratingPreset.value = true
            generatingSubId.value = subId
            statusMessage.value = "正在生成场景对话…"
            runCatching { api.generatePresetScenario(groupId, subId, token) }
                .onSuccess { scene ->
                    statusMessage.value = ""
                    val now = java.time.Instant.now().toString()
                    onReady(
                        ScenarioSummary(
                            sceneId = scene.sceneId,
                            title = scene.title,
                            summary = scene.summary,
                            roles = scene.roles,
                            lineCount = scene.lines.size,
                            sourceStart = now,
                            sourceEnd = now,
                            createdAt = now,
                        )
                    )
                }
                .onFailure { statusMessage.value = it.message ?: "生成失败" }
            generatingSubId.value = null
            isGeneratingPreset.value = false
        }
    }

    /** 进入练习前：若指导/对话方式设为 ask，先弹窗让用户选择（对话中不可切换）。 */
    fun startScenarioPractice(summary: ScenarioSummary, roleId: String) {
        if (auth.token == null) { statusMessage.value = "请先登录"; return }
        if (guidancePreference.value == "ask" || conversationPreference.value == "ask") {
            pendingPractice.value = summary to roleId
            return
        }
        conversationMode.value = resolvedConversationMode(conversationPreference.value)
        guidanceMode.value = if (guidancePreference.value == "final") "final" else "realtime"
        beginPractice(summary, roleId)
    }

    /** 把「对话方式偏好」解析为本次会话实际模式：voice（语音模型对话）仅高级会员生效，否则回退沉浸式。 */
    private fun resolvedConversationMode(pref: String): String = when (pref) {
        "manual" -> "manual"
        "voice" -> if (user.value?.planTier == "premium") "voice" else "immersive"
        else -> "immersive"   // immersive / ask
    }

    /** 「对话前询问」确认：按所选模式开始，并按需记住偏好。 */
    fun confirmPendingPractice(
        conversation: String,
        guidance: String,
        rememberConversation: Boolean,
        rememberGuidance: Boolean,
    ) {
        val pending = pendingPractice.value ?: return
        val mode = if (conversation == "voice" && user.value?.planTier != "premium") "immersive" else conversation
        conversationMode.value = mode
        guidanceMode.value = if (guidance == "final") "final" else "realtime"
        if (rememberConversation) { conversationPreference.value = mode; auth.conversationPreference = mode }
        if (rememberGuidance) { guidancePreference.value = guidanceMode.value; auth.guidancePreference = guidanceMode.value }
        pendingPractice.value = null
        beginPractice(pending.first, pending.second)
    }

    fun cancelPendingPractice() { pendingPractice.value = null }

    private fun beginPractice(summary: ScenarioSummary, roleId: String) {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            isWorking.value = true
            runCatching {
                scenario = api.scenarioDetail(summary.sceneId, token)
                selectedRole = roleId
                appendChat(ChatMessage.Sender.USER, "练习：${summary.title}（扮演${roleName(roleId)}）")
                if (shouldUseVoiceLLM()) {
                    // 高级会员沉浸式 + 实时语音大模型：用 /roleplay/start 建会话拿 session_id，再用 WS 直接语音对话
                    practice.stop(); voice.stop()
                    val state = api.startRoleplay(summary.sceneId, roleId, token)
                    statusMessage.value = "实时语音对练已开始"
                    showVoiceLLM.value = true
                    realtime.start(auth.baseUrl, token, state.sessionId, scenario?.title ?: summary.title)
                } else {
                    val state = api.startRoleplay(summary.sceneId, roleId, token)
                    isVoiceActive.value = true
                    showImmersive.value = true   // 进入对话字幕全屏
                    handleRoleplayState(state)
                }
            }.onFailure { statusMessage.value = it.message ?: "开始失败" }
            isWorking.value = false
        }
    }

    /** 本次是否走实时语音大模型：仅高级会员且本次对话方式为「语音模型对话」。 */
    private fun shouldUseVoiceLLM(): Boolean =
        user.value?.planTier == "premium" && conversationMode.value == "voice"

    /** 结束实时语音对练并请求评分（保留界面展示评分）。 */
    fun endVoiceLLMPractice() = realtime.end()

    /** 关闭实时语音沉浸式界面（评分已展示或用户放弃）。 */
    fun dismissVoiceLLM() {
        realtime.cancel()
        showVoiceLLM.value = false
    }

    fun toggleVoiceConversation() {
        val rp = roleplay
        // 与 iOS 对齐：先判完成态（可重玩），再判暂停/继续，避免竞态下 replay 分支不可达
        when {
            rp == null -> appendChat(
                ChatMessage.Sender.ASSISTANT,
                "先选个场景：点上方卡片，或用底部按钮采集。",
            )
            rp.completed -> replayScenario()
            isVoiceActive.value -> {
                isVoiceActive.value = false
                cancelAnswerTimeout()
                practice.stop()
                voice.stop()
                statusMessage.value = "语音对话已暂停"
            }
            else -> {
                isVoiceActive.value = true
                listenForNextTurn()
            }
        }
    }

    /** 重新对练当前场景：在同一场景上新开一轮，可在完成后直接重玩。 */
    fun replayScenario() {
        val sceneId = scenario?.sceneId ?: roleplay?.scenario?.sceneId
        val role = selectedRole.ifEmpty { roleplay?.selectedRole.orEmpty() }
        if (sceneId == null || role.isEmpty()) {
            appendChat(ChatMessage.Sender.ASSISTANT, "先选个场景：点上方卡片，或用底部按钮采集。")
            return
        }
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            isWorking.value = true
            spokenMessageIds.clear()
            runCatching {
                val state = api.startRoleplay(sceneId, role, token)
                isVoiceActive.value = true
                showImmersive.value = true
                handleRoleplayState(state)
            }.onFailure { statusMessage.value = it.message ?: "重新开始失败" }
            isWorking.value = false
        }
    }

    /** 「结束后指导」模式下按需取最终评分与建议；中途退出也能拿到结果。 */
    fun requestFinalEvaluation() {
        val rp = roleplay ?: run {
            appendChat(ChatMessage.Sender.ASSISTANT, "还没有进行中的对练。")
            return
        }
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            isWorking.value = true
            runCatching { api.evaluateRoleplay(rp.sessionId, token) }
                .onSuccess { state ->
                    roleplay = state
                    roleplayState.value = state
                    state.latestFeedback?.takeIf { it.isNotBlank() }?.let {
                        appendChat(ChatMessage.Sender.ASSISTANT, it)
                        if (autoSpeakAI.value) voice.speak(it) {}
                    }
                }
                .onFailure { statusMessage.value = it.message ?: "评估失败" }
            isWorking.value = false
        }
    }

    fun setGuidancePreference(value: String) {
        val v = if (value in listOf("realtime", "final", "ask")) value else "ask"
        guidancePreference.value = v
        auth.guidancePreference = v
    }

    fun setConversationPreference(value: String) {
        val v = if (value in listOf("immersive", "manual", "ask", "voice")) value else "ask"
        conversationPreference.value = v
        auth.conversationPreference = v
    }

    fun setShowSubtitles(value: Boolean) {
        showSubtitles.value = value
        auth.showSubtitles = value
    }

    fun setFontScale(value: Float) {
        val normalized = value.coerceIn(0.85f, 1.35f)
        fontScale.value = normalized
        auth.fontScale = normalized
    }

    fun setAutoSpeakAI(value: Boolean) {
        autoSpeakAI.value = value
        auth.autoSpeakAI = value
    }

    fun setContinuousVoice(value: Boolean) {
        continuousVoice.value = value
        auth.continuousVoice = value
    }

    fun setAutoCaptureEnabled(value: Boolean) {
        autoCaptureEnabled.value = value
        auth.autoCaptureEnabled = value
        if (!value && autoCaptureRunning && capture.isRecording) {
            capture.stop()
            autoCaptureRunning = false
            uploadPendingAndRefresh()
        }
    }

    private fun persistCaptureWindows() {
        captureWindows.value = captureWindows.value.toList()  // 触发新列表实例，刷新 UI
        auth.captureWindows = captureWindows.value.joinToString(";") { it.first + "-" + it.second }
    }

    fun addCaptureWindow() {
        captureWindows.value = captureWindows.value + ("09:00" to "18:00")
        persistCaptureWindows()
    }

    fun removeCaptureWindow(index: Int) {
        captureWindows.value = captureWindows.value.filterIndexed { i, _ -> i != index }
        persistCaptureWindows()
    }

    fun setCaptureWindow(index: Int, start: String, end: String) {
        captureWindows.value = captureWindows.value.mapIndexed { i, w -> if (i == index) (start to end) else w }
        persistCaptureWindows()
    }

    fun setAppearance(value: String) {
        val v = if (value in listOf("system", "light", "dark")) value else "system"
        appearance.value = v
        auth.appearance = v
    }

    private suspend fun submitUtterance(text: String) {
        partialSubtitle.value = ""
        cancelAnswerTimeout()
        appendChat(ChatMessage.Sender.USER, text)
        submitAnswer(text)
    }

    private suspend fun submitAnswer(answer: String) {
        val token = auth.token ?: return
        val rp = roleplay ?: return
        isWorking.value = true
        runCatching { api.sendRoleplayMessage(rp.sessionId, answer, guidanceMode.value, token) }
            .onSuccess { state ->
                state.latestFeedback?.takeIf { it.isNotBlank() }?.let {
                    appendChat(ChatMessage.Sender.ASSISTANT, it)
                }
                handleRoleplayState(state, spokenPreface = state.latestFeedback)
            }
            .onFailure { statusMessage.value = it.message ?: "提交失败" }
        isWorking.value = false
    }

    private fun handleRoleplayState(state: RoleplayState, spokenPreface: String? = null) {
        roleplay = state
        roleplayState.value = state
        scenario = state.scenario
        selectedRole = state.selectedRole
        if (state.completed) {
            isVoiceActive.value = false
            cancelAnswerTimeout()
            practice.stop()
        }

        val newAiMessages = state.messages.filter { it.speaker == "ai" && spokenMessageIds.add(it.id) }
        for (message in newAiMessages) {
            // 要求 13：AI 台词中英双语字幕
            val subtitle = if (showSubtitles.value) "${message.content}\n中文：${message.translation.orEmpty()}" else message.content
            appendChat(ChatMessage.Sender.ASSISTANT, subtitle)
        }
        state.nextLine?.let { next ->
            // 轮到用户：先显示中文提示
            appendChat(ChatMessage.Sender.SYSTEM, "轮到你：${next.sourceText}")
        }

        // 「自动朗读 AI 台词」关闭时不朗读，直接进入聆听
        val toSpeak = if (autoSpeakAI.value) {
            listOfNotNull(spokenPreface?.takeIf { it.isNotBlank() }) + newAiMessages.map { it.content }
        } else {
            emptyList()
        }
        if (toSpeak.isEmpty()) {
            listenForNextTurn()
        } else {
            speakSequence(toSpeak, 0)
        }
    }

    private fun speakSequence(texts: List<String>, index: Int) {
        if (index >= texts.size) { listenForNextTurn(); return }
        voice.speak(texts[index]) { speakSequence(texts, index + 1) }
    }

    private fun listenForNextTurn() {
        if (!isVoiceActive.value) return
        // 手工触发式：不自动开麦，等用户长按说话
        if (conversationMode.value != "immersive") return
        if (!continuousVoice.value) return
        if (roleplay?.completed != false || roleplay?.nextLine == null) return
        practice.start()
        scheduleAnswerTimeout()
    }

    // ---- 手工触发式：长按说话、滑动取消/发送 ----

    fun beginManualUtterance() {
        if (!isVoiceActive.value) return
        cancelAnswerTimeout()
        voice.stop()
        practice.start(autoSubmit = false)
    }

    fun sendManualUtterance() = practice.stopAndEmit()

    fun cancelManualUtterance() = practice.cancel()

    private fun startCaptureScheduleLoop() {
        if (captureScheduleJob != null) return
        captureScheduleJob = viewModelScope.launch {
            while (true) {
                evaluateAutomaticCaptureWindow()
                enforceCaptureQuotaDuringRecording()
                enforceCaptureSecondsLimit()
                retryPendingUploadsIfNeeded()
                delay(30_000)
            }
        }
    }

    private fun evaluateAutomaticCaptureWindow() {
        if (!autoCaptureEnabled.value || auth.token == null || isVoiceActive.value) return
        val insideWindow = isNowInsideAutomaticCaptureWindow()
        // 抑制只在「被停止的那个时段内」有效；时段变化/结束后清除
        if (autoCaptureSuppressedUntil != null && !(insideWindow && currentAutoWindowEnd() == autoCaptureSuppressedUntil)) {
            autoCaptureSuppressedUntil = null
        }
        val suppressed = insideWindow && autoCaptureSuppressedUntil != null
        if (insideWindow && !capture.isRecording && !suppressed) {
            autoCaptureRunning = true
            // 自动采集同样先校验额度，超额则不启动并提示
            viewModelScope.launch { startCaptureWithQuotaCheck("已按默认时间开始采集") }
        } else if (!insideWindow && autoCaptureRunning && capture.isRecording) {
            commitCaptureSeconds()
            capture.stop()
            autoCaptureRunning = false
            statusMessage.value = "已按默认时间结束采集"
            uploadPendingAndRefresh()
        }
    }

    /** 当前时刻所在采集时段的结束时间；不在任何时段返回 null。 */
    private fun currentAutoWindowEnd(now: LocalTime = LocalTime.now()): LocalTime? {
        captureWindows.value.forEach { (s, e) ->
            val start = parseCaptureTime(s) ?: return@forEach
            val end = parseCaptureTime(e) ?: return@forEach
            if (start == end) return@forEach
            val inside = if (start.isBefore(end)) !now.isBefore(start) && now.isBefore(end)
                else !now.isBefore(start) || now.isBefore(end)
            if (inside) return end
        }
        return null
    }

    private fun isNowInsideAutomaticCaptureWindow(now: LocalTime = LocalTime.now()): Boolean {
        // 任一时段命中即视为在采集窗口内（支持多个时段）
        return captureWindows.value.any { (s, e) ->
            val start = parseCaptureTime(s) ?: return@any false
            val end = parseCaptureTime(e) ?: return@any false
            if (start == end) return@any false
            if (start.isBefore(end)) !now.isBefore(start) && now.isBefore(end)
            else !now.isBefore(start) || now.isBefore(end)
        }
    }

    private fun parseCaptureTime(value: String): LocalTime? {
        val parts = value.trim().split(":")
        if (parts.size != 2) return null
        val hour = parts[0].toIntOrNull() ?: return null
        val minute = parts[1].toIntOrNull() ?: return null
        return runCatching { LocalTime.of(hour, minute) }.getOrNull()
    }

    // ---- 套餐 / 工单 ----

    /** 按档位可选套餐：非会员=全部；基础=续费基础+升级高级；高级=续费高级。 */
    fun availablePlans(): List<PlanItem> = when (user.value?.planTier) {
        "premium" -> plans.value.filter { it.tier == "premium" }
        else -> plans.value
    }

    fun loadMyTickets() {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            runCatching { api.mySupportTickets(token) }.onSuccess { myTickets.value = it.items }
        }
    }

    fun submitSupportTicket(category: String, subject: String, body: String) {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            runCatching { api.createSupportTicket(category, subject, body, token) }
                .onSuccess { statusMessage.value = "工单已提交，我们会尽快处理"; loadMyTickets() }
                .onFailure { statusMessage.value = it.message ?: "提交失败" }
        }
    }

    /** 要求 12：超时未答 → AI 主动给指导再继续 */
    private fun scheduleAnswerTimeout() {
        cancelAnswerTimeout()
        answerTimeoutJob = viewModelScope.launch {
            delay(20_000)
            if (!isVoiceActive.value) return@launch
            val next = roleplay?.nextLine ?: return@launch
            if (partialSubtitle.value.isNotBlank()) { scheduleAnswerTimeout(); return@launch }
            practice.stop()
            appendChat(ChatMessage.Sender.ASSISTANT, "提示：${next.sourceText}\n试着说：${next.english}")
            // 下一句提示仅在指导区展示，不做 AI 语音播报（item 3）
            listenForNextTurn()
        }
    }

    private fun cancelAnswerTimeout() {
        answerTimeoutJob?.cancel()
        answerTimeoutJob = null
    }

    fun roleName(roleId: String): String =
        scenario?.roles?.firstOrNull { it.id == roleId }?.name ?: roleId

    // ---- 沉浸式字幕控制 ----

    /** 重听 AI 最近一句台词。 */
    fun replayLastAi() {
        val last = roleplay?.messages?.lastOrNull { it.speaker == "ai" } ?: return
        voice.speak(last.content) {}
    }

    fun interruptAiAndContinue() {
        voice.stop()
        listenForNextTurn()
    }

    /** 给当前轮的中文提示（仅展示、不语音播报，item 3），随后继续聆听。 */
    fun requestHint() {
        val next = roleplay?.nextLine ?: return
        appendChat(ChatMessage.Sender.ASSISTANT, "提示：${next.sourceText}\n试着说：${next.english}")
        cancelAnswerTimeout()
        practice.stop()
        listenForNextTurn()
    }

    /** 关闭沉浸式：先暂停语音对话，再退出全屏。 */
    fun closeImmersive() {
        if (isVoiceActive.value) toggleVoiceConversation()
        showImmersive.value = false
    }

    // ---- 账单 / 会员 / 充值 ----

    fun refreshBilling() {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            runCatching { api.billingAccount(token) }
                .onSuccess { billing.value = it; user.value = it.user }
                .onFailure { statusMessage.value = it.message ?: "" }
        }
    }

    fun loadPlans() {
        viewModelScope.launch {
            runCatching { api.planCatalog() }.onSuccess { plans.value = it.items }
        }
    }

    /** 开通会员：生成套餐支付订单（微信/支付宝），支付成功后激活会员 */
    fun subscribe(planId: String, method: String) {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            isWorking.value = true
            runCatching { api.createRecharge(0, method, token, planId) }
                .onSuccess { rechargeOrder.value = it; statusMessage.value = it.message }
                .onFailure { statusMessage.value = it.message ?: "开通失败" }
            isWorking.value = false
        }
    }

    fun createRecharge(amountCents: Int, method: String) {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            runCatching { api.createRecharge(amountCents, method, token) }
                .onSuccess { rechargeOrder.value = it }
                .onFailure { statusMessage.value = it.message ?: "创建失败" }
        }
    }

    fun confirmRecharge() {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            val order = rechargeOrder.value ?: return@launch
            runCatching { api.confirmRecharge(order.orderId, token) }
                .onSuccess {
                    billing.value = it; user.value = it.user; rechargeOrder.value = null
                    statusMessage.value = "支付成功，当前为${it.user.tierName}"
                }
                .onFailure { statusMessage.value = it.message ?: "确认失败" }
        }
    }

    // ---- 高级会员音频上传 ----

    fun loadAudioJobs() {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            runCatching { api.audioJobs(token) }.onSuccess { audioJobs.value = it.items }
        }
    }

    fun uploadRecording(file: File) {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            // App 本地判断文件大小与时长（无需后端往返），超限直接拒绝
            if (file.length() > 300L * 1024 * 1024) { statusMessage.value = "文件过大，最大 300MB"; return@launch }
            val durationSec = audioDurationSeconds(file)
            if (durationSec > 6 * 3600) { statusMessage.value = "音频过长，最长 6 小时"; return@launch }

            isUploadingAudio.value = true
            // App 计算文件哈希做上传前去重预检：同文件已生成过场景则直接复用，省去整段上传
            val hash = fileSha256(file)
            if (hash != null) {
                val pre = runCatching { api.audioPrecheck(hash, token) }.getOrNull()
                if (pre?.duplicate == true) {
                    statusMessage.value = "该录音此前已生成过场景，已直接复用，无需重复上传"
                    loadAudioJobs(); loadTodayScenarios()
                    isUploadingAudio.value = false
                    return@launch
                }
            }
            runCatching {
                api.uploadAudioResumable(file, token) { fraction ->
                    statusMessage.value = "上传中 ${(fraction * 100).toInt()}%"
                }
            }
                .onSuccess {
                    statusMessage.value = "上传成功，正在转写生成场景"
                    for (attempt in 0 until 60) {
                        loadAudioJobs()
                        delay(4_000)
                        val active = audioJobs.value.any { it.status in listOf("pending", "transcribing", "generating") }
                        if (!active) break
                    }
                    loadTodayScenarios()
                }
                .onFailure { statusMessage.value = it.message ?: "上传失败" }
            isUploadingAudio.value = false
        }
    }

    /** 流式计算文件 SHA-256（与后端一致），用于上传前去重预检。 */
    private suspend fun fileSha256(file: File): String? = withContext(kotlinx.coroutines.Dispatchers.IO) {
        runCatching {
            val md = java.security.MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buf = ByteArray(1024 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n <= 0) break
                    md.update(buf, 0, n)
                }
            }
            md.digest().joinToString("") { "%02x".format(it) }
        }.getOrNull()
    }

    /** 本地读取音频时长（秒）；读不到返回 0（按通过处理，交由后端兜底）。 */
    private suspend fun audioDurationSeconds(file: File): Long = withContext(kotlinx.coroutines.Dispatchers.IO) {
        runCatching {
            val mmr = android.media.MediaMetadataRetriever()
            mmr.setDataSource(file.absolutePath)
            val ms = mmr.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            mmr.release()
            ms / 1000L
        }.getOrDefault(0L)
    }

    /**
     * 主界面已无聊天列表（chatMessages 已移除）。这里把助手 / 系统的引导与错误提示
     * 汇到顶部状态文案；用户回声不展示（沉浸式界面用 roleplayState 字幕呈现真实对话）。
     */
    private fun appendChat(sender: ChatMessage.Sender, text: String) {
        if (sender == ChatMessage.Sender.USER) return
        val trimmed = text.trim()
        if (trimmed.isEmpty() || statusMessage.value == trimmed) return
        statusMessage.value = trimmed
    }
}

/** 解析多时段字符串 "HH:mm-HH:mm;HH:mm-HH:mm"；空则回退单个默认时段。 */
private fun parseCaptureWindows(raw: String): List<Pair<String, String>> {
    val list = raw.split(";").mapNotNull { seg ->
        val p = seg.trim().split("-")
        if (p.size == 2 && p[0].isNotBlank() && p[1].isNotBlank()) p[0].trim() to p[1].trim() else null
    }
    return list.ifEmpty { listOf("09:00" to "18:00") }
}
