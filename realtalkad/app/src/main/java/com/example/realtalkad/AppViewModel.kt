package com.example.realtalkad

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.realtalkad.data.AIChatMessage
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
import com.example.realtalkad.data.TranscriptItem
import com.example.realtalkad.speech.PracticeSpeech
import com.example.realtalkad.speech.SpeechCapture
import com.example.realtalkad.speech.VoicePlayer
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.time.Instant
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

/** 与 iOS AppModel 等价的业务编排层。 */
class AppViewModel(application: Application) : AndroidViewModel(application) {

    val auth = AuthStore(application)
    val api = ApiClient { auth.baseUrl }
    val capture = SpeechCapture(application)
    val practice = PracticeSpeech(application)
    val voice = VoicePlayer(application)

    val user = MutableStateFlow<AppUser?>(null)
    val billing = MutableStateFlow<BillingAccount?>(null)
    val plans = MutableStateFlow<List<PlanItem>>(emptyList())
    val todayScenarios = MutableStateFlow<List<ScenarioSummary>>(emptyList())
    val chatMessages = MutableStateFlow<List<ChatMessage>>(emptyList())
    val partialSubtitle = MutableStateFlow("")
    val isRecording = MutableStateFlow(false)
    val isListening = MutableStateFlow(false)
    val isSpeaking = MutableStateFlow(false)
    val isWorking = MutableStateFlow(false)
    val isVoiceActive = MutableStateFlow(false)
    val statusMessage = MutableStateFlow("")
    val rechargeOrder = MutableStateFlow<RechargeOrder?>(null)
    val audioJobs = MutableStateFlow<List<AudioJob>>(emptyList())
    val isUploadingAudio = MutableStateFlow(false)
    val showSubtitles = MutableStateFlow(true)

    private var scenario: Scenario? = null
    private var roleplay: RoleplayState? = null
    private var selectedRole = ""
    private val pendingTranscripts = mutableListOf<TranscriptItem>()
    private val spokenMessageIds = mutableSetOf<String>()
    private var answerTimeoutJob: Job? = null
    private val messageId = AtomicLong(0)

    val isAuthenticated: StateFlow<AppUser?> get() = user

    init {
        capture.onSegment = { text ->
            synchronized(pendingTranscripts) {
                pendingTranscripts += TranscriptItem(UUID.randomUUID().toString(), Instant.now().toString(), text)
            }
        }
        capture.onStateChange = { isRecording.value = it }
        practice.onPartial = { partialSubtitle.value = it }
        practice.onStateChange = { isListening.value = it }
        practice.onUtterance = { text -> viewModelScope.launch { submitUtterance(text) } }
        voice.onStateChange = { isSpeaking.value = it }

        appendChat(ChatMessage.Sender.ASSISTANT, "今天想还原哪段真实对话？点上方「今日场景」卡片，或先点右上角开始采集。")
        bootstrap()
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
                    api.wechatLogin(code, null)
                } else {
                    // 未配置 AppID 或未装微信：开发模拟登录
                    api.wechatLogin(auth.devWeChatCode, "微信用户")
                }
            }
                .onSuccess {
                    auth.token = it.token
                    user.value = it.user
                    statusMessage.value = "登录成功"
                    refreshBilling(); loadTodayScenarios(); loadPlans()
                }
                .onFailure { statusMessage.value = it.message ?: "登录失败" }
            isWorking.value = false
        }
    }

    fun logout() {
        auth.clear()
        user.value = null
        billing.value = null
        statusMessage.value = "已退出登录"
    }

    // ---- 采集 ----

    fun toggleRecording() {
        if (capture.isRecording) {
            capture.stop()
            uploadPendingAndRefresh()
        } else {
            capture.start()
            appendChat(ChatMessage.Sender.ASSISTANT, "我已开始采集真实对话（仅上传转写文字，不上传音频）。")
        }
    }

    private fun uploadPendingAndRefresh() {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            kotlinx.coroutines.delay(400) // 等最后的识别结果落入队列
            val items = synchronized(pendingTranscripts) {
                val copy = pendingTranscripts.toList(); pendingTranscripts.clear(); copy
            }
            if (items.isEmpty()) {
                appendChat(ChatMessage.Sender.ASSISTANT, "这次没有采集到语音内容。模拟器麦克风常不可用，建议用真机；现在你也可以直接发「录入对话 老板来一份牛肉面；不要香菜」。")
                return@launch
            }
            runCatching { api.uploadTranscripts(items, token) }
                .onSuccess {
                    appendChat(ChatMessage.Sender.ASSISTANT, "已采集并上传 ${it.uploaded} 句真实对话，正在生成今日场景…")
                    loadTodayScenarios()
                }
                .onFailure { appendChat(ChatMessage.Sender.ASSISTANT, "上传失败，请检查网络后重试。"); statusMessage.value = it.message ?: "" }
        }
    }

    /** 文字录入真实对话（模拟器无麦克风时的回退路径）。 */
    fun ingestTypedConversation(raw: String) {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            val body = raw.removePrefix("录入对话").removePrefix("录入").trim(' ', '：', ':', '\n')
            if (body.isEmpty()) {
                appendChat(ChatMessage.Sender.ASSISTANT, "把今天真实说过的话发给我，例如：录入对话 老板来一份牛肉面；不要香菜。")
                return@launch
            }
            val sentences = body.split('。', '！', '？', '!', '?', '；', ';', '\n')
                .map { it.trim() }.filter { it.isNotEmpty() }
                .ifEmpty { listOf(body) }
            val now = Instant.now()
            val items = sentences.mapIndexed { i, s ->
                TranscriptItem(UUID.randomUUID().toString(), now.plusSeconds(i.toLong()).toString(), s)
            }
            runCatching { api.uploadTranscripts(items, token) }
                .onSuccess {
                    appendChat(ChatMessage.Sender.ASSISTANT, "已录入 ${it.uploaded} 句真实对话，正在生成今日场景…")
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
                    if (it.generated) appendChat(ChatMessage.Sender.ASSISTANT, "我根据你今天的真实对话生成了新的场景，点卡片开练。")
                }
                .onFailure { statusMessage.value = it.message ?: "" }
        }
    }

    fun startScenarioPractice(summary: ScenarioSummary, roleId: String) {
        viewModelScope.launch {
            val token = auth.token ?: return@launch
            isWorking.value = true
            runCatching {
                scenario = api.scenarioDetail(summary.sceneId, token)
                selectedRole = roleId
                appendChat(ChatMessage.Sender.USER, "练习：${summary.title}（扮演${roleName(roleId)}）")
                val state = api.startRoleplay(summary.sceneId, roleId, token)
                isVoiceActive.value = true
                handleRoleplayState(state)
            }.onFailure { statusMessage.value = it.message ?: "开始失败" }
            isWorking.value = false
        }
    }

    fun toggleVoiceConversation() {
        if (isVoiceActive.value) {
            isVoiceActive.value = false
            cancelAnswerTimeout()
            practice.stop()
            voice.stop()
            statusMessage.value = "语音对话已暂停"
        } else if (roleplay != null && roleplay?.completed == false) {
            isVoiceActive.value = true
            listenForNextTurn()
        } else {
            appendChat(
                ChatMessage.Sender.ASSISTANT,
                "先选一个练习场景：点上方「今日场景」卡片，或点右上角按钮采集今天的真实对话。",
            )
        }
    }

    fun sendText(text: String) {
        val prompt = text.trim()
        if (prompt.isEmpty()) return
        appendChat(ChatMessage.Sender.USER, prompt)
        if (prompt.startsWith("录入")) {
            ingestTypedConversation(prompt)
            return
        }
        val rp = roleplay
        if (rp != null && !rp.completed && rp.nextLine != null) {
            viewModelScope.launch { submitAnswer(prompt) }
        } else {
            viewModelScope.launch { askAI(prompt) }
        }
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
        runCatching { api.sendRoleplayMessage(rp.sessionId, answer, token) }
            .onSuccess { state ->
                state.latestFeedback?.takeIf { it.isNotBlank() }?.let {
                    appendChat(ChatMessage.Sender.ASSISTANT, it)
                }
                handleRoleplayState(state, spokenPreface = state.latestFeedback)
            }
            .onFailure { statusMessage.value = it.message ?: "提交失败" }
        isWorking.value = false
    }

    private suspend fun askAI(prompt: String) {
        val token = auth.token ?: run { statusMessage.value = "请先登录"; return }
        isWorking.value = true
        val history = chatMessages.value.takeLast(20).map {
            AIChatMessage(
                role = when (it.sender) {
                    ChatMessage.Sender.USER -> "user"
                    ChatMessage.Sender.ASSISTANT -> "assistant"
                    ChatMessage.Sender.SYSTEM -> "system"
                },
                content = it.text,
            )
        }
        runCatching { api.aiChat(prompt, history, scenario?.sceneId, roleplay?.sessionId, token) }
            .onSuccess { appendChat(ChatMessage.Sender.ASSISTANT, it.reply) }
            .onFailure { statusMessage.value = it.message ?: "请求失败" }
        isWorking.value = false
    }

    private fun handleRoleplayState(state: RoleplayState, spokenPreface: String? = null) {
        roleplay = state
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

        val toSpeak = listOfNotNull(spokenPreface?.takeIf { it.isNotBlank() }) + newAiMessages.map { it.content }
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
        if (roleplay?.completed != false || roleplay?.nextLine == null) return
        practice.start()
        scheduleAnswerTimeout()
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
            appendChat(ChatMessage.Sender.ASSISTANT, "别紧张，我来帮你。\n中文提示：${next.sourceText}\n可以这样说：${next.english}")
            voice.speak("Take your time. Try saying: ${next.english}") { listenForNextTurn() }
        }
    }

    private fun cancelAnswerTimeout() {
        answerTimeoutJob?.cancel()
        answerTimeoutJob = null
    }

    private fun roleName(roleId: String): String =
        scenario?.roles?.firstOrNull { it.id == roleId }?.name ?: roleId

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
            isUploadingAudio.value = true
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

    private fun appendChat(sender: ChatMessage.Sender, text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        val last = chatMessages.value.lastOrNull()
        if (last?.sender == sender && last.text == trimmed) return
        chatMessages.value = chatMessages.value + ChatMessage(messageId.incrementAndGet(), sender, trimmed)
    }
}
