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
import com.example.realtalkad.speech.RoleplayStreamClient
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
    val stream = RoleplayStreamClient(application)
    val freeStream = RoleplayStreamClient(application)   // 自由对话（一对一语音老师）复用同一套流协议
    val realtime = RealtimeVoiceClient(application)
    private val transcriptStore = TranscriptFileStore(application)

    val user = MutableStateFlow<AppUser?>(null)
    val billing = MutableStateFlow<BillingAccount?>(null)
    val plans = MutableStateFlow<List<PlanItem>>(emptyList())
    val todayScenarios = MutableStateFlow<List<ScenarioSummary>>(emptyList())
    val partialSubtitle = MutableStateFlow("")
    val practiceHint = MutableStateFlow<String?>(null)   // 超时未答时的「可以这样说」英文提示，显示在指导区
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
    // AI 朗读音色（后端 TTS）
    val ttsVoices = MutableStateFlow<List<String>>(emptyList())
    val ttsCurrentVoice = MutableStateFlow("")
    val ttsConfigured = MutableStateFlow(false)
    val showChineseHint = MutableStateFlow(auth.showChineseHint)
    val guidanceMode = MutableStateFlow("realtime")            // 当前会话生效（不可中途切）
    val conversationMode = MutableStateFlow("immersive")       // 当前会话生效
    val guidancePreference = MutableStateFlow(auth.guidancePreference)     // ask/realtime/final
    val conversationPreference = MutableStateFlow(auth.conversationPreference) // ask/voice/immersive/manual
    val pendingPractice = MutableStateFlow<Triple<ScenarioSummary, String, Boolean>?>(null) // (场景, 角色, 是否继续上次)；非空时弹「对话前询问」
    val showVoiceLLM = MutableStateFlow(false)                          // 控制实时语音沉浸式界面呈现
    val fontScale = MutableStateFlow(auth.fontScale)
    val autoCaptureEnabled = MutableStateFlow(auth.autoCaptureEnabled)
    // 多个自动采集时段（"HH:mm" 起止对）
    val captureWindows = MutableStateFlow(parseCaptureWindows(auth.captureWindows))
    val appearance = MutableStateFlow(auth.appearance)   // system/light/dark
    val myTickets = MutableStateFlow<List<com.example.realtalkad.data.SupportTicket>>(emptyList())
    val roleplayState = MutableStateFlow<RoleplayState?>(null)
    val showImmersive = MutableStateFlow(false)
    // 自由对话（一对一语音老师）：无场景、无指导区，只有字幕
    val showFreeTalk = MutableStateFlow(false)
    // 私教字幕行：speaker(user/ai) + 文本 + 中文翻译(AI行=中译；用户说中文时=英译)
    data class FreeTalkLine(val speaker: String, val text: String, val translation: String = "")
    val freeTalkMessages = MutableStateFlow<List<FreeTalkLine>>(emptyList())
    val freeTalkStatus = MutableStateFlow("")
    val freeTalkAiSpeaking = MutableStateFlow(false)
    val freeTalkLevel = MutableStateFlow(0f)
    val freeTalkAiLevel = MutableStateFlow(0f)
    val freeTalkPaused = MutableStateFlow(false)
    val freeTalkWorking = MutableStateFlow(false)   // 已发送、等待后端转写+回复（圈变红，不能打断）

    fun toggleFreeTalkPause() {
        freeTalkPaused.value = freeStream.togglePause()
    }

    fun startFreeTalk() {
        val token = auth.token ?: run { presentFailure("请先登录", title = "无法开始自由对话"); return }
        freeTalkMessages.value = emptyList()
        freeTalkStatus.value = "连接中…"
        freeTalkWorking.value = false
        freeStream.onFreeTalkHistory = { items ->
            freeTalkMessages.value = items.map { FreeTalkLine(it.first, it.second) }; freeTalkStatus.value = ""
        }
        freeStream.onCommitted = { freeTalkWorking.value = true }   // 已发送 → 等后端
        freeStream.onUserText = { t, tr -> freeTalkMessages.value = freeTalkMessages.value + FreeTalkLine("user", t, tr) }
        freeStream.onAIText = { t, tr -> freeTalkWorking.value = false; freeTalkMessages.value = freeTalkMessages.value + FreeTalkLine("ai", t, tr) }
        freeStream.onError = { msg -> freeTalkWorking.value = false; freeTalkStatus.value = msg }
        // 轻提示(没听清/噪音)：清掉“正在思考”红态、显示一下即可，流程已回到聆听
        freeStream.onResultMessage = { msg -> freeTalkWorking.value = false; freeTalkStatus.value = msg }
        freeStream.onStatus = { msg -> freeTalkStatus.value = msg }
        freeStream.onAiSpeaking = { s -> freeTalkAiSpeaking.value = s }
        freeStream.onUserLevel = { l -> freeTalkLevel.value = l }
        freeStream.onAiLevel = { l -> freeTalkAiLevel.value = l }
        freeTalkPaused.value = false
        showFreeTalk.value = true
        freeStream.start(api.freeTalkStreamUrl(token), "realtime")
    }

    fun stopFreeTalk() {
        freeStream.stop()
        freeTalkWorking.value = false
        showFreeTalk.value = false
    }

    // ---- 学习提醒（智能电话）：App 主导触发（多活后端只提供幂等查询/拒绝接口，绝不重复来电）----
    val reminderEnabled = MutableStateFlow(auth.reminderEnabled)
    val reminderMode = MutableStateFlow(auth.reminderMode)              // smart=智能 / timed=定时
    val reminderWindows = MutableStateFlow(parseWindows(auth.reminderWindows))   // 智能：提醒学习时段
    val reminderTimes = MutableStateFlow(auth.reminderTimes.split(";").filter { it.isNotBlank() })  // 定时：HH:mm 列表
    val incomingReminder = MutableStateFlow<ScenarioSummary?>(null)     // 非空=弹出「私教来电」
    val reminderPracticeScene = MutableStateFlow<ScenarioSummary?>(null) // 接听并选「现在练习」→ 主界面弹角色选择
    private val firedTimedKeys = mutableSetOf<String>()

    private fun parseWindows(raw: String): List<Pair<String, String>> =
        raw.split(";").filter { it.contains("-") }.map { val p = it.split("-"); p[0] to p[1] }

    fun setReminderEnabled(v: Boolean) {
        reminderEnabled.value = v; auth.reminderEnabled = v
        // 同步后台周期任务（WorkManager，系统最小 15 分钟）；命中来电时发通知，点开进 App 弹「私教来电」
        ReminderWorker.schedule(getApplication(), v)
    }
    fun setReminderMode(v: String) { reminderMode.value = v; auth.reminderMode = v }
    fun setReminderWindows(v: List<Pair<String, String>>) {
        reminderWindows.value = v; auth.reminderWindows = v.joinToString(";") { "${it.first}-${it.second}" }
    }
    fun setReminderTimes(v: List<String>) { reminderTimes.value = v; auth.reminderTimes = v.joinToString(";") }

    init {
        // App 启动同步后台周期任务状态（开关开着就保证已调度）
        ReminderWorker.schedule(getApplication(), auth.reminderEnabled)
        // 学习提醒：进 App 15 秒后先查一次（覆盖「点通知打开」的场景），之后每 10 分钟一次（用户要求的频率）
        viewModelScope.launch {
            kotlinx.coroutines.delay(15_000)
            runCatching { checkPracticeReminder() }
            while (true) {
                kotlinx.coroutines.delay(600_000)
                runCatching { checkPracticeReminder() }
            }
        }
    }

    private fun minuteOf(hhmm: String): Int {
        val p = hhmm.split(":"); return (p.getOrNull(0)?.toIntOrNull() ?: 0) * 60 + (p.getOrNull(1)?.toIntOrNull() ?: 0)
    }

    /** 学习提醒判定：App 采集信号 → POST 给后端综合裁决（后端只被动应答，多活安全）。
     *  App 端只做「明确忙碌」先拦（对话/采集中）与时段/时间点门槛；
     *  空闲综合判断（深夜/运动/心率/环境音/记忆作息）由后端在收到报文后执行。 */
    suspend fun checkPracticeReminder() {
        if (!reminderEnabled.value) return
        val token = auth.token ?: return
        if (incomingReminder.value != null || reminderPracticeScene.value != null) return
        // 明确忙碌：正在对话/私教/实时语音/采集/处理中都不打扰
        if (isVoiceActive.value || showFreeTalk.value || showVoiceLLM.value || showImmersive.value ||
            isRecording.value || isWorking.value) return
        val cal = java.util.Calendar.getInstance()
        val nowMin = cal.get(java.util.Calendar.HOUR_OF_DAY) * 60 + cal.get(java.util.Calendar.MINUTE)
        // in_user_window：null=没设时段(24h 交给后端综合判断)；true=在自设时段内(时段优先)；时段外直接不查
        var inUserWindow: Boolean? = null
        if (reminderMode.value == "smart") {
            val windows = reminderWindows.value
            if (windows.isNotEmpty()) {
                val inside = windows.any { (s, e) ->
                    val sm = minuteOf(s); val em = minuteOf(e)
                    if (sm <= em) nowMin in sm..em else (nowMin >= sm || nowMin <= em)
                }
                if (!inside) return   // 用户设了时段且不在内 → 连后端都不必查
                inUserWindow = true
            }
        } else {
            // 定时：到达某个时间点(±5 分钟，10 分钟一查)且今天该点没响过；定时=用户明确指定 → 视同自设时段
            val dayKey = "${cal.get(java.util.Calendar.YEAR)}-${cal.get(java.util.Calendar.DAY_OF_YEAR)}"
            val hit = reminderTimes.value.firstOrNull { t ->
                kotlin.math.abs(nowMin - minuteOf(t)) <= 5 && !firedTimedKeys.contains("$dayKey-$t")
            } ?: return
            firedTimedKeys.add("$dayKey-$hit")
            inUserWindow = true
        }
        val resp = runCatching { api.reminderCheck(buildReminderRequest(inUserWindow), token) }.getOrNull() ?: return
        if (resp.decision == "call" && resp.scenario != null) {
            incomingReminder.value = resp.scenario
        }
    }

    companion object {
        /** 组装信号报文（心率/环境音/运动暂传空——协议已留位，接入传感器后填充即可，后端有则用无则跳过）。 */
        fun buildReminderRequest(inUserWindow: Boolean?): com.example.realtalkad.data.ReminderCheckRequest {
            val cal = java.util.Calendar.getInstance()
            val dayStart = java.util.Calendar.getInstance().apply {
                set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0)
                set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
            }
            val fmt = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", java.util.Locale.US)
            return com.example.realtalkad.data.ReminderCheckRequest(
                localDayStart = fmt.format(dayStart.time),
                localHour = cal.get(java.util.Calendar.HOUR_OF_DAY),
                weekday = (cal.get(java.util.Calendar.DAY_OF_WEEK) + 5) % 7,   // 转 0=周一
                inUserWindow = inUserWindow,
                motion = null, ambientLevel = null, heartRate = null,
            )
        }
    }

    /** 挂断/暂不练习：该场景永不再来电（后端幂等记录），以后手工进场景练即可。 */
    fun declineReminder() {
        val scenario = incomingReminder.value ?: return
        incomingReminder.value = null
        val token = auth.token ?: return
        viewModelScope.launch { runCatching { api.reminderDismiss(scenario.sceneId, token) } }
    }

    /** 接听并选「现在练习」：走与点场景卡完全相同的流程（选角色 → 继续/重新 → 按设置询问对话方式）。 */
    fun acceptReminder() {
        val scenario = incomingReminder.value ?: return
        incomingReminder.value = null
        voice.stop()
        reminderPracticeScene.value = scenario
    }
    val presetCatalog = MutableStateFlow<List<com.example.realtalkad.data.PresetSceneGroup>>(emptyList()) // 通用场景：运维预置的全局场景（分组）
    // 中断流程的系统/模型/额度异常：弹失败提示框（不像 statusMessage 只在顶部短暂提示）
    val failureAlert = MutableStateFlow<FailureAlert?>(null)

    data class FailureAlert(val title: String, val message: String)

    fun dismissFailureAlert() { failureAlert.value = null }

    /** 弹出失败提示框。message 为空时给出兜底说明。统一用弹框，避免与 Toast 重复提示。 */
    private fun presentFailure(message: String?, title: String = "操作未完成") {
        val text = message?.trim().orEmpty().ifEmpty { "发生未知错误，请稍后重试。" }
        failureAlert.value = FailureAlert(title, text)
    }

    private var scenario: Scenario? = null
    private var roleplay: RoleplayState? = null
    private var selectedRole = ""
    // 用户是否已退出对话界面：退出后即使后台回包也不再播报 AI 语音/续听
    private var conversationExited = false
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
        practice.onAudioFile = { file -> viewModelScope.launch { submitRoleplayAudio(file) } }
        voice.onStateChange = { isSpeaking.value = it }
        voice.onLevel = { aiAudioLevel.value = it }
        // AI 台词改用后端 TTS（可选音色）；后端不可用 VoicePlayer 自动回退本机 TTS
        voice.scope = viewModelScope
        voice.audioProvider = { text, cache -> auth.token?.let { t -> runCatching { api.ttsSpeak(text, t, cache) }.getOrNull() } }
        // 沉浸式后端语音流（WS）：复用现有音圈电平绑定，结果回来直接刷新对练状态
        stream.onUserLevel = { practiceAudioLevel.value = it }
        stream.onAiLevel = { aiAudioLevel.value = it }
        stream.onAiSpeaking = { isSpeaking.value = it }
        stream.onCommitted = { isWorking.value = true }   // 已发送 → 「已发送，正在识别评分…」
        stream.onResultState = { jsonStr -> isWorking.value = false; applyStreamState(jsonStr) }
        stream.onResultMessage = { msg -> isWorking.value = false; statusMessage.value = msg }
        stream.onStatus = { msg -> statusMessage.value = msg }
        stream.onCompleted = { isVoiceActive.value = false }
        stream.onError = { msg ->
            isWorking.value = false
            isVoiceActive.value = false
            stream.stop()
            presentFailure(msg, title = "对话中断")
        }
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
        presentFailure("今日免费采集时长已用完，已停止并提交生成场景；升级会员可不限时长。", title = "采集已停止")
        uploadPendingAndRefresh()
    }

    /** 开始采集前查询剩余额度：超额拦截、不足提示但允许；记录额度用于采集中自动停止。 */
    private suspend fun startCaptureWithQuotaCheck(okMessage: String) {
        captureRemainingTokens = null
        // 非会员每日采集时长限额（客户端本地强制）
        if (isNonMember() && nonmemberCaptureSecondsLimit() > 0 && capturedSecondsToday() >= nonmemberCaptureSecondsLimit()) {
            presentFailure("今日免费采集时长已用完，升级会员可不限时长，或明天再来。", title = "无法开始采集")
            return
        }
        val token = auth.token
        val quota = if (token != null) runCatching { api.captureQuota(token) }.getOrNull() else null
        if (quota != null) {
            if (!quota.canCapture) {
                presentFailure(quota.message.ifBlank { "当前额度不足，暂时无法采集。" }, title = "无法开始采集")
                return
            }
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
            presentFailure("本月 AI 额度已用完，已自动停止采集并提交生成场景；下月自动恢复。", title = "采集已停止")
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
        uploadPendingAndRefresh(notifyFailure = true)
    }

    /** notifyFailure=true（用户手动停止采集）失败弹提示框；自动停止/后台重试时静默（内容本地保留、会重试）。 */
    private fun uploadPendingAndRefresh(notifyFailure: Boolean = false) {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            kotlinx.coroutines.delay(400) // 等最后的识别结果落入队列
            val items = transcriptStore.pending()
            if (items.isEmpty()) {
                statusMessage.value = "没采到声音"
                return@launch
            }
            statusMessage.value = "正在上传…（${items.size} 句）"
            runCatching { api.uploadCaptureItems(items, token) }
                .onSuccess {
                    transcriptStore.remove(items.map { item -> item.id }.toSet())
                    // 异步生成：上传成功即可，无需等待场景；生成完成后会出现在场景列表
                    statusMessage.value = "上传成功，场景生成中，稍后在列表查看"
                    loadTodayScenarios()
                }
                .onFailure {
                    if (notifyFailure) {
                        presentFailure("采集内容上传失败：${it.message ?: ""}。内容已保留，稍后会自动重试。", title = "上传失败")
                    } else {
                        statusMessage.value = "上传失败：${it.message ?: ""}"
                    }
                }
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
                    statusMessage.value = "已录入 ${it.acceptedItems} 句，场景生成中，稍后在列表查看"
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

    /** 删除用户自己的场景（长按菜单触发）。 */
    fun deleteScenario(sceneId: String) {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            runCatching { api.deleteScenario(sceneId, token) }
                .onSuccess {
                    todayScenarios.value = todayScenarios.value.filterNot { it.sceneId == sceneId }
                    statusMessage.value = "场景已删除"
                }
                .onFailure { presentFailure(it.message, title = "删除失败") }
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

    /** 通用场景已含完整对话：直接把预置场景转成摘要，走与「自己场景」完全一样的「选角色 → 对练」流程。 */
    fun presetSummary(scene: com.example.realtalkad.data.PresetSceneItem): ScenarioSummary {
        val now = java.time.Instant.now().toString()
        return ScenarioSummary(
            sceneId = scene.sceneId,
            title = scene.title,
            summary = "",
            roles = scene.roles,
            lineCount = scene.lineCount,
            sourceStart = now,
            sourceEnd = now,
            createdAt = now,
            lastScore = scene.lastScore,
            lastPracticedAt = scene.lastPracticedAt,
            inProgress = scene.inProgress,
            resumeProgress = scene.resumeProgress,
        )
    }

    /** 进入练习前：若指导/对话方式设为 ask，先弹窗让用户选择（对话中不可切换）。 */
    fun startScenarioPractice(summary: ScenarioSummary, roleId: String, resume: Boolean = false) {
        if (auth.token == null) { statusMessage.value = "请先登录"; return }
        if (guidancePreference.value == "ask" || conversationPreference.value == "ask") {
            pendingPractice.value = Triple(summary, roleId, resume)
            return
        }
        conversationMode.value = resolvedConversationMode(conversationPreference.value)
        guidanceMode.value = if (guidancePreference.value == "final") "final" else "realtime"
        beginPractice(summary, roleId, resume)
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
        beginPractice(pending.first, pending.second, pending.third)
    }

    fun cancelPendingPractice() { pendingPractice.value = null }

    private fun beginPractice(summary: ScenarioSummary, roleId: String, resume: Boolean = false) {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            isWorking.value = true
            runCatching {
                scenario = api.scenarioDetail(summary.sceneId, token)
                selectedRole = roleId
                appendChat(ChatMessage.Sender.USER, "练习：${summary.title}（扮演${roleName(roleId)}${if (resume) "·继续上次" else ""}）")
                if (shouldUseVoiceLLM()) {
                    // 高级会员沉浸式 + 实时语音大模型：用 /roleplay/start 建会话拿 session_id，再用 WS 直接语音对话
                    practice.stop(); voice.stop()
                    val state = api.startRoleplay(summary.sceneId, roleId, token, resume)
                    statusMessage.value = "实时语音对练已开始"
                    showVoiceLLM.value = true
                    realtime.start(auth.baseUrl, token, state.sessionId, scenario?.title ?: summary.title)
                } else {
                    val state = api.startRoleplay(summary.sceneId, roleId, token, resume)
                    conversationExited = false
                    isVoiceActive.value = true
                    showImmersive.value = true   // 进入对话字幕全屏
                    applyStartState(state)
                }
            }.onFailure { presentFailure(it.message, title = "无法开始练习") }
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
                stream.stop()
                isWorking.value = false   // 停流后回包不再来，清掉避免主界面按钮卡死（#5）
                statusMessage.value = "语音对话已暂停"
            }
            else -> {
                isVoiceActive.value = true
                if (conversationMode.value == "immersive") startImmersiveStream() else listenForNextTurn()
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
                conversationExited = false
                isVoiceActive.value = true
                showImmersive.value = true
                applyStartState(state)
            }.onFailure { presentFailure(it.message, title = "重新开始失败") }
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
                        // 说对了只展示「参考说法」不朗读；说错了纠正要朗读
                        if (state.latestAccepted != true) voice.speak(it, cache = false) {}
                    }
                }
                .onFailure { presentFailure(it.message, title = "评分获取失败") }
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

    fun setShowChineseHint(value: Boolean) {
        showChineseHint.value = value
        auth.showChineseHint = value
    }


    fun setFontScale(value: Float) {
        val normalized = value.coerceIn(0.85f, 1.35f)
        fontScale.value = normalized
        auth.fontScale = normalized
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
            .onFailure {
                // 系统/模型/额度异常中断了对话流程：停止本轮并弹失败提示框（保留会话，可重试或退出）
                isVoiceActive.value = false
                practice.stop()
                cancelAnswerTimeout()
                presentFailure(it.message, title = "对话中断")
            }
        isWorking.value = false
    }

    fun loadTtsVoices() {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            runCatching { api.ttsVoices(token) }.onSuccess {
                ttsVoices.value = it.voices
                ttsCurrentVoice.value = it.current
                ttsConfigured.value = it.configured
            }
        }
    }

    fun setTtsVoice(voice: String) {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            if (voice.isBlank()) return@launch
            runCatching { api.setTtsVoice(voice, token) }.onSuccess {
                ttsVoices.value = it.voices
                ttsCurrentVoice.value = it.current
                statusMessage.value = "已设置 AI 音色：$voice"
            }
        }
    }

    /** 后端语音回合：把录好的一句音频上传给后端识别+评分+发音纠正（方式1/2 共用）。 */
    private suspend fun submitRoleplayAudio(file: java.io.File) {
        partialSubtitle.value = ""
        cancelAnswerTimeout()
        val token = auth.token ?: run { file.delete(); return }
        val rp = roleplay ?: run { file.delete(); return }
        isWorking.value = true
        runCatching { api.sendRoleplayAudio(rp.sessionId, guidanceMode.value, file, token) }
            .onSuccess { state ->
                state.recognizedText?.trim()?.takeIf { it.isNotBlank() }?.let { recognized ->
                    appendChat(ChatMessage.Sender.USER, recognized)
                    // 只在【本句没通过、还要重说】时提示发音；说对已进入下一句就不再提示上一句
                    val missed = state.pronunciation.filter { !it.ok }.map { it.word }
                    if (state.latestAccepted == false && missed.isNotEmpty()) {
                        appendChat(ChatMessage.Sender.SYSTEM, "发音再注意：${missed.joinToString("、")}")
                    }
                }
                state.latestFeedback?.takeIf { it.isNotBlank() }?.let {
                    appendChat(ChatMessage.Sender.ASSISTANT, it)
                }
                handleRoleplayState(state, spokenPreface = state.latestFeedback)
            }
            .onFailure {
                isVoiceActive.value = false
                practice.stop()
                cancelAnswerTimeout()
                presentFailure(it.message, title = "对话中断")
            }
        isWorking.value = false
        file.delete()
    }

    /** 沉浸式是否走后端语音流（WebSocket：流式 + 抢话打断）。 */
    private fun startImmersiveStream() {
        val token = auth.token ?: return
        val sid = roleplay?.sessionId ?: return
        isVoiceActive.value = true
        stream.start(api.roleplayStreamUrl(sid, token), guidanceMode.value)
    }

    /** 开始对练后：沉浸式由 WS 流驱动，其余走原 HTTP 流程。 */
    private fun applyStartState(state: RoleplayState) {
        if (conversationMode.value == "immersive") {
            handleRoleplayState(state, drivenByStream = true)   // 上屏开场，不本地朗读
            startImmersiveStream()
        } else {
            handleRoleplayState(state)
        }
    }

    /** WS 推来的整轮状态：上屏识别文本/发音提示，并刷新对练状态。 */
    private fun applyStreamState(jsonStr: String) {
        val state = api.decodeRoleplayState(jsonStr) ?: return
        state.recognizedText?.takeIf { it.isNotBlank() }?.let { rec ->
            appendChat(ChatMessage.Sender.USER, rec)
            // 只在【本句没通过、还要重说】时提示发音；说对已进入下一句就不再提示上一句
            val missed = state.pronunciation.filter { !it.ok }.map { it.word }
            if (state.latestAccepted == false && missed.isNotEmpty()) {
                appendChat(ChatMessage.Sender.SYSTEM, "发音再注意：${missed.joinToString("、")}")
            }
        }
        state.latestFeedback?.takeIf { it.isNotBlank() }?.let { appendChat(ChatMessage.Sender.ASSISTANT, it) }
        handleRoleplayState(state, drivenByStream = true)
    }

    private fun handleRoleplayState(state: RoleplayState, spokenPreface: String? = null, drivenByStream: Boolean = false) {
        roleplay = state
        roleplayState.value = state
        scenario = state.scenario
        selectedRole = state.selectedRole
        practiceHint.value = null   // 进入新一轮，清掉上一轮的超时英文提示
        if (state.completed) {
            isVoiceActive.value = false
            cancelAnswerTimeout()
            practice.stop()
        }

        val newAiMessages = state.messages.filter { it.speaker == "ai" && spokenMessageIds.add(it.id) }
        for (message in newAiMessages) {
            // 字幕里的中文翻译是否显示，由「中文提示」开关决定
            val subtitle = if (showChineseHint.value && message.translation.orEmpty().isNotBlank())
                "${message.content}\n中文：${message.translation.orEmpty()}" else message.content
            appendChat(ChatMessage.Sender.ASSISTANT, subtitle)
        }
        state.nextLine?.let { next ->
            // 轮到用户：指导提示永远给中文（与「中文提示」开关无关）
            appendChat(ChatMessage.Sender.SYSTEM, "轮到你：${next.sourceText}")
        }

        // 用户已退出对话界面：状态已更新即可，绝不再播报 AI 语音或继续听
        if (conversationExited) return
        // 沉浸式后端语音流：识别/朗读/抢话都在流里，不本地朗读/聆听
        if (drivenByStream) return

        // 自动朗读 AI 台词为固定行为。指导(spokenPreface)实时合成、不缓存(cache=false)；
        // AI 台词走缓存(命中预生成,cache 默认 true)。故先念指导、再念台词、最后聆听。
        // 说对了(accepted)的指导是「参考说法」，上屏展示即可、不朗读(避免夹在 AI 下一句前念)；说错了纠正要朗读。
        val preface = spokenPreface?.takeIf { it.isNotBlank() && state.latestAccepted != true }
        val aiTexts = newAiMessages.map { it.content }
        when {
            preface != null -> voice.speak(preface, cache = false) {
                if (aiTexts.isEmpty()) listenForNextTurn() else speakSequence(aiTexts, 0)
            }
            aiTexts.isEmpty() -> listenForNextTurn()
            else -> speakSequence(aiTexts, 0)
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
        val next = roleplay?.nextLine ?: return
        if (roleplay?.completed != false) return
        practice.expectedPhrases = listOf(next.english)   // 用目标台词偏置识别，提升转写准确度
        practice.start()
        scheduleAnswerTimeout()
    }

    // ---- 手工触发式：长按说话、滑动取消/发送 ----

    fun beginManualUtterance() {
        if (!isVoiceActive.value) return
        cancelAnswerTimeout()
        voice.stop()
        roleplay?.nextLine?.let { practice.expectedPhrases = listOf(it.english) }
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

    fun submitSupportTicket(category: String, subject: String, body: String, images: List<String> = emptyList(), onDone: () -> Unit = {}) {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            runCatching { api.createSupportTicket(category, subject, body, images, token) }
                .onSuccess { statusMessage.value = "工单已提交，我们会尽快处理"; loadMyTickets(); onDone() }
                .onFailure { presentFailure(it.message, title = "工单提交失败") }
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
            // 在沉浸式指导区显示英文参考（之前 appendChat 只进主聊天流、沉浸式看不到）
            practiceHint.value = "可以这样说：${next.english}"
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
        // 用户主动退出：标记已退出 + 彻底停止，使后台仍在处理的那一轮回包回来后不再播报/续听
        conversationExited = true
        cancelAnswerTimeout()
        practice.stop()
        voice.stop()
        stream.stop()
        isVoiceActive.value = false
        // 关键：停流后那一轮「识别评分」回包不会再来，必须清 isWorking，
        // 否则退出后主界面 isBusy 恒真、场景与采集按钮全灰、用户无法再操作（#5）。
        isWorking.value = false
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
                .onFailure { presentFailure(it.message, title = "开通失败") }
            isWorking.value = false
        }
    }

    fun createRecharge(amountCents: Int, method: String) {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            runCatching { api.createRecharge(amountCents, method, token) }
                .onSuccess { rechargeOrder.value = it }
                .onFailure { presentFailure(it.message, title = "下单失败") }
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
                .onFailure { presentFailure(it.message, title = "支付确认失败") }
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
            if (file.length() > 300L * 1024 * 1024) { presentFailure("文件过大，最大 300MB。", title = "无法上传"); return@launch }
            val durationSec = audioDurationSeconds(file)
            if (durationSec > 6 * 3600) { presentFailure("音频过长，最长 6 小时。", title = "无法上传"); return@launch }

            isUploadingAudio.value = true
            // 断点续传上传（每个报文带文件 MD5，服务端按 MD5 路由到对应语音服务器）；
            // 服务端已有同文件则秒回成功。处理改为服务器端定时任务转写+生成场景，App 不再等待。
            runCatching {
                api.uploadAudioResumable(file, token) { fraction ->
                    statusMessage.value = "上传中 ${(fraction * 100).toInt()}%"
                }
            }
                .onSuccess { alreadyDone ->
                    statusMessage.value = if (alreadyDone)
                        "该录音此前已上传，无需重复上传"
                    else
                        "上传成功，场景生成中，稍后在列表查看"
                }
                .onFailure { presentFailure(it.message, title = "上传失败") }
            isUploadingAudio.value = false
        }
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
