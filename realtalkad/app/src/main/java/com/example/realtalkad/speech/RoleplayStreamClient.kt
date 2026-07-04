package com.example.realtalkad.speech

import android.content.Context
import android.media.MediaPlayer
import android.media.MediaRecorder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * 沉浸式（方式2）后端语音流：okhttp WebSocket 连 /roleplay/stream。
 * 录一句音频→commit；AI 朗读时检测到用户能量→interrupt 抢话；顺序播放后端 TTS 音频帧。
 * 识别/评分都在后端，本类只负责录音+VAD+抢话+播放+收发协议。回调都切到主线程交给 ViewModel。
 */
class RoleplayStreamClient(private val context: Context) {
    var onResultState: ((String) -> Unit)? = null   // 整轮完整状态 JSON
    var onResultMessage: ((String) -> Unit)? = null  // 没听清等提示
    var onCompleted: (() -> Unit)? = null
    var onError: ((String) -> Unit)? = null
    var onStatus: ((String) -> Unit)? = null   // 「重连中/已重连」等提示
    var onCommitted: (() -> Unit)? = null      // 一句录音已提交后端（用于「已发送，正在识别评分…」状态提示）
    var onUserLevel: ((Float) -> Unit)? = null
    var onAiLevel: ((Float) -> Unit)? = null
    var onAiSpeaking: ((Boolean) -> Unit)? = null
    // 自由对话（/freetalk/stream）事件：历史回放 + 双方逐句字幕。协议其余部分与沉浸式完全一致。
    var onFreeTalkHistory: ((List<Pair<String, String>>) -> Unit)? = null   // (speaker, text)
    var onUserText: ((String, String) -> Unit)? = null   // (text, translation)
    var onAIText: ((String, String) -> Unit)? = null      // (text, translation)

    private val wsClient = OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()
    private var webSocket: WebSocket? = null
    private val scope = CoroutineScope(Dispatchers.Main)
    private var guidanceMode = "realtime"
    private var active = false
    // 断线重连
    private var wsUrl: String = ""
    private var connected = false
    private var reconnectAttempts = 0
    private val maxReconnect = 5
    private var reconnectJob: Job? = null

    private var recorder: MediaRecorder? = null
    private var file: File? = null
    private var meterJob: Job? = null
    private var heardSpeech = false
    private var silentMs = 0L
    private var bargeTicks = 0
    private var aiSpeakMs = 0L                 // AI 已连续朗读时长（用于抢话宽限期）
    private val bargeGraceMs = 1000L            // AI 开口后这段时间内不允许抢话，保证说完开头
    private var suppressAiAudio = false         // 打断后丢弃该轮迟到的 AI 音频，直到下一次 commit
    private var utteranceMs = 0L
    private var voicedMs = 0L                   // 本句真正“像在说话”的时长：太短=纯噪音，不上传
    private var noiseFloor = 0.1f            // 自适应环境噪声本底（绝对阈值在有底噪时会一直判成“在说话”）
    private val tickMs = 100L
    private val silenceThresholdMs = 1000L   // 说完到发送的停顿判定，越小越跟手
    private val maxUtteranceMs = 15000L       // 兜底：一句(含持续噪声)最长强制提交，避免永远卡在“聆听”
    private val speechMargin = 0.10f          // 高于本底这么多算“在说话”
    private val silenceMargin = 0.045f        // 低于本底+这么多算“静音”
    private val bargeLevel = 0.3f     // 抢话能量阈值(略高，避免残余回声误触)
    private val bargeNeeded = 3

    private var aiSpeaking = false
    private var player: MediaPlayer? = null
    private val aiQueue = ArrayDeque<ByteArray>()
    private var incoming = java.io.ByteArrayOutputStream()
    private var receivingAudio = false

    fun start(wsUrl: String, guidanceMode: String) {
        stop()
        this.wsUrl = wsUrl
        this.guidanceMode = guidanceMode
        active = true
        paused = false
        reconnectAttempts = 0
        connectWS()   // 录音在收到 state 事件后开始（首连/重连都走这条路径）
    }

    /** 临时暂停/恢复：暂停时停录音+停 AI 朗读（不断开 WS），再点恢复聆听。返回当前是否已暂停。 */
    var paused = false
        private set

    fun togglePause(): Boolean {
        if (paused) {
            paused = false
            startRecording()
            return false
        }
        paused = true
        runCatching { recorder?.stop() }; runCatching { recorder?.release() }; recorder = null
        file?.delete(); file = null
        runCatching { webSocket?.send(JSONObject(mapOf("type" to "interrupt")).toString()) }
        suppressAiAudio = true   // 暂停即打断：该轮迟到音频作废，恢复后从下一次 commit 重新开始
        runCatching { player?.stop() }; runCatching { player?.release() }; player = null
        aiQueue.clear()
        aiSpeaking = false
        scope.launch { onAiSpeaking?.invoke(false); onUserLevel?.invoke(0f); onAiLevel?.invoke(0f) }
        return true
    }

    private fun connectWS() {
        if (!active || wsUrl.isBlank()) return
        webSocket = wsClient.newWebSocket(Request.Builder().url(wsUrl).build(), listener)
    }

    private fun scheduleReconnect() {
        if (!active) return
        runCatching { webSocket?.cancel() }
        webSocket = null
        connected = false
        reconnectAttempts++
        if (reconnectAttempts > maxReconnect) { onError?.invoke("网络已断开，请重试"); stop(); return }
        onStatus?.invoke("网络不稳，正在重连…")
        val delayMs = minOf(8000L, (1000L shl (reconnectAttempts - 1)))   // 1,2,4,8,8s
        reconnectJob?.cancel()
        reconnectJob = scope.launch { delay(delayMs); if (active) connectWS() }
    }

    fun stop() {
        active = false
        connected = false
        paused = false
        reconnectJob?.cancel(); reconnectJob = null
        runCatching { webSocket?.send(JSONObject(mapOf("type" to "bye")).toString()) }
        runCatching { webSocket?.close(1000, null) }
        webSocket = null
        meterJob?.cancel(); meterJob = null
        runCatching { recorder?.stop() }; runCatching { recorder?.release() }; recorder = null
        file?.delete(); file = null
        runCatching { player?.stop() }; runCatching { player?.release() }; player = null
        aiQueue.clear()
        aiSpeaking = false
        onAiSpeaking?.invoke(false)
        onUserLevel?.invoke(0f); onAiLevel?.invoke(0f)
    }

    // ---- 录音 + VAD + 抢话 ----

    private fun startRecording() {
        runCatching { recorder?.stop() }; runCatching { recorder?.release() }
        file?.delete()
        val out = File(context.cacheDir, "rt-stream-${UUID.randomUUID()}.m4a")
        val rec = if (android.os.Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else @Suppress("DEPRECATION") MediaRecorder()
        try {
            // VOICE_COMMUNICATION 启用系统回声消除(AEC)/降噪：否则扬声器放的 AI 声音被麦克风拾到→被当成抢话→AI 刚说一个词就被打断
            rec.setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
            rec.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            rec.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            rec.setAudioSamplingRate(16000)
            rec.setAudioChannels(1)
            rec.setOutputFile(out.absolutePath)
            rec.prepare()
            rec.start()
        } catch (e: Exception) {
            runCatching { rec.release() }; out.delete(); return
        }
        recorder = rec; file = out
        heardSpeech = false; silentMs = 0; bargeTicks = 0; utteranceMs = 0; voicedMs = 0
        if (meterJob == null) {
            meterJob = scope.launch {
                while (active) { delay(tickMs); meterTick() }
            }
        }
    }

    private fun meterTick() {
        val r = recorder ?: return
        val amp = runCatching { r.maxAmplitude }.getOrDefault(0)
        val level = (amp / 12000f).coerceIn(0f, 1f)
        onUserLevel?.invoke(level)
        if (!connected) return   // 断线/重连期间只显示电平，不提交
        if (aiSpeaking) {
            aiSpeakMs += tickMs
            // 抢话：AEC 已消回声；再加宽限期 + 更高阈值，保证 AI 至少说完开头不被自己的声音打断
            if (aiSpeakMs >= bargeGraceMs && level >= bargeLevel) {
                bargeTicks++
                if (bargeTicks >= bargeNeeded) bargeIn()
            } else bargeTicks = 0
            return
        }
        aiSpeakMs = 0
        // 自适应 VAD：以「相对环境本底」判定，避免安静房间底噪被误判为一直在说话（从不提交、从不变红）
        if (!heardSpeech) noiseFloor = (noiseFloor * 0.92f + level * 0.08f).coerceAtMost(0.5f)
        val speechThresh = noiseFloor + speechMargin
        val silenceThresh = noiseFloor + silenceMargin
        if (level >= speechThresh) {
            heardSpeech = true; silentMs = 0; utteranceMs += tickMs; voicedMs += tickMs
        } else if (heardSpeech) {
            utteranceMs += tickMs
            if (level <= silenceThresh) silentMs += tickMs else silentMs = 0
            if (silentMs >= silenceThresholdMs) { commitUtterance(); return }
        }
        // 兜底：一句(含持续噪声)说太久 → 强制提交
        if (heardSpeech && utteranceMs >= maxUtteranceMs) commitUtterance()
    }

    private fun bargeIn() {
        runCatching { webSocket?.send(JSONObject(mapOf("type" to "interrupt")).toString()) }
        suppressAiAudio = true   // 被打断的这轮就此作废：其后迟到的 AI 音频全部丢弃，直到下一次 commit
        runCatching { player?.stop() }; runCatching { player?.release() }; player = null
        aiQueue.clear()
        aiSpeaking = false; onAiSpeaking?.invoke(false); onAiLevel?.invoke(0f)
        startRecording()
    }

    private fun commitUtterance() {
        runCatching { recorder?.stop() }
        val out = file
        // 噪音门槛：真正“像在说话”的时长太短(<400ms)视为纯噪音，静默丢弃回到聆听，不上传也不提示
        val voicedEnough = heardSpeech && voicedMs >= 400
        file = null
        if (voicedEnough && out != null && out.length() > 1200) {
            runCatching {
                suppressAiAudio = false   // 新一轮开始，恢复接收 AI 音频
                webSocket?.send(out.readBytes().toByteString())
                webSocket?.send(JSONObject(mapOf("type" to "commit", "format" to ".m4a", "guidance_mode" to guidanceMode)).toString())
                scope.launch { onCommitted?.invoke() }
            }
        }
        out?.delete()
        startRecording()
    }

    // ---- 收 AI 音频并顺序播放 ----

    private fun enqueueAi(data: ByteArray) {
        if (paused || suppressAiAudio) return   // 暂停/被打断流程的迟到音频直接丢弃
        aiQueue.addLast(data)
        if (player == null) playNextAi()
    }

    private fun playNextAi() {
        val data = aiQueue.removeFirstOrNull()
        if (data == null) {
            val wasSpeaking = aiSpeaking
            aiSpeaking = false; onAiSpeaking?.invoke(false); onAiLevel?.invoke(0f)
            // 关键：AI 刚说完 → 立刻重开一段干净录音。否则录音文件里带着 AI 从扬声器放出的整段声音，
            // 转写会把 AI 的话混进用户的话（字幕里用户气泡出现 AI 台词）。
            if (wasSpeaking && active && connected) startRecording()
            return
        }
        val f = File(context.cacheDir, "rt-ai-${UUID.randomUUID()}.mp3")
        f.writeBytes(data)
        try {
            val mp = MediaPlayer()
            mp.setDataSource(f.absolutePath)
            mp.setOnCompletionListener { runCatching { it.release() }; player = null; f.delete(); playNextAi() }
            mp.setOnErrorListener { _, _, _ -> f.delete(); false }
            mp.prepare()
            player = mp
            aiSpeaking = true; onAiSpeaking?.invoke(true)
            mp.start()
        } catch (e: Exception) {
            f.delete(); playNextAi()
        }
    }

    // ---- WebSocket ----

    private val listener = object : WebSocketListener() {
        override fun onMessage(ws: WebSocket, text: String) {
            scope.launch { if (active) handleEvent(text) }
        }
        override fun onMessage(ws: WebSocket, bytes: ByteString) {
            scope.launch { if (active && receivingAudio) incoming.write(bytes.toByteArray()) }
        }
        override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) {
            scope.launch { if (active) scheduleReconnect() }   // 网络抖动自动重连，不直接报错停掉
        }
        override fun onClosing(ws: WebSocket, code: Int, reason: String) {
            scope.launch { if (active && code != 1000) scheduleReconnect() }
        }
    }

    private fun handleEvent(text: String) {
        val obj = runCatching { JSONObject(text) }.getOrNull() ?: return
        when (obj.optString("type")) {
            "state" -> {
                // 首连/重连：标记已连、复位重试，按后端完整状态恢复字幕/进度，丢弃断线残留音频，干净重录
                connected = true
                if (reconnectAttempts > 0) onStatus?.invoke("已重连")
                reconnectAttempts = 0
                runCatching { player?.stop() }; runCatching { player?.release() }; player = null
                aiQueue.clear(); receivingAudio = false; incoming = java.io.ByteArrayOutputStream()
                aiSpeaking = false; onAiSpeaking?.invoke(false)
                obj.optJSONObject("state")?.let { onResultState?.invoke(it.toString()) }
                // 自由对话：state 直接带历史字幕列表
                obj.optJSONArray("messages")?.let { arr ->
                    val items = (0 until arr.length()).mapNotNull { i ->
                        arr.optJSONObject(i)?.let { m -> m.optString("speaker", "ai") to m.optString("text") }
                    }
                    onFreeTalkHistory?.invoke(items)
                }
                startRecording()
            }
            "user_text" -> onUserText?.invoke(obj.optString("text"), obj.optString("translation"))
            "ai_text" -> onAIText?.invoke(obj.optString("text"), obj.optString("translation"))
            "ai_audio_begin" -> { receivingAudio = true; incoming = java.io.ByteArrayOutputStream() }
            "ai_audio_end" -> {
                receivingAudio = false
                val data = incoming.toByteArray()
                if (data.isNotEmpty()) enqueueAi(data)
                incoming = java.io.ByteArrayOutputStream()
            }
            "result" -> {
                val state = obj.optJSONObject("state")
                if (state != null) onResultState?.invoke(state.toString())
                else obj.optString("feedback").takeIf { it.isNotBlank() }?.let { onResultMessage?.invoke(it) }
            }
            "completed" -> onCompleted?.invoke()
            // 可恢复的轻提示（没听清/噪音等）：显示一下即可，流程回到聆听，绝不当错误中断
            "notice" -> onResultMessage?.invoke(obj.optString("detail"))
            "error" -> onError?.invoke(obj.optString("detail").ifBlank { "对话出错" })
        }
    }
}
