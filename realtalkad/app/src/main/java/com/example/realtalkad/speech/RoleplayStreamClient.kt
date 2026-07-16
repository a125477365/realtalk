package com.example.realtalkad.speech

import android.content.Context
import android.media.MediaPlayer
import android.media.MediaRecorder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
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
    var onFreeTalkHistory: ((List<Triple<String, String, String>>) -> Unit)? = null   // (speaker, text, tone)
    /** (text, translation, 词级发音详情, 语速wpm)——词级来自本地语音服务器 whisper 置信度，云端无词级为空 */
    var onUserText: ((String, String, List<WordScore>, Int) -> Unit)? = null
    var onAIText: ((String, String, String) -> Unit)? = null      // (text, translation, tone 情绪标签)
    var onTerminated: ((String) -> Unit)? = null          // 涉敏感话题被后端中断：提示并退出会话

    /** 词级发音详情（低置信 ≈ 发音待提高） */
    data class WordScore(val word: String, val probability: Double)

    /** 手动触发模式（常规「点击说话」）：录音开始/发送由用户点按驱动，不做自动静音提交/语音抢话。 */
    var manualCommit = false
    var manualRecording = false
        private set

    /** live 全双工（GPT-Live 式）：帧持续上行（含 AI 说话期间），轮次判定/打断全在服务端。 */
    var liveMode = false

    /** 顶栏「自动播放 AI 语音」总开关：关闭时丢弃推来的 AI 音频（字幕不受影响，卡内波形按钮可单句重听）。 */
    var autoPlayAI = true

    /** WS 已连上且收到 state（对外可见：点说话按钮时若已掉线由上层整体重连）。 */
    val isConnected: Boolean get() = connected

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

    // 采集（PCM 流式：AudioRecord 16kHz mono Int16，边说边发）
    private var audioRecord: android.media.AudioRecord? = null
    private var echoCanceler: android.media.audiofx.AcousticEchoCanceler? = null
    private var captureJob: Job? = null
    private val preroll = ArrayDeque<ByteArray>()     // 说话起点前的预滚（保住句首）
    private val prerollMax = 5
    private var streamingUtterance = false
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
        resetUtterance(sendReset = true)
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
        captureJob?.cancel(); captureJob = null
        runCatching { audioRecord?.stop() }; runCatching { audioRecord?.release() }; audioRecord = null
        runCatching { echoCanceler?.release() }; echoCanceler = null
        preroll.clear()
        runCatching { player?.stop() }; runCatching { player?.release() }; player = null
        aiQueue.clear()
        aiSpeaking = false
        onAiSpeaking?.invoke(false)
        onUserLevel?.invoke(0f); onAiLevel?.invoke(0f)
    }

    // ---- 录音 + VAD + 抢话 ----

    private fun startRecording() {
        resetUtterance(sendReset = false)
        if (audioRecord != null) return
        val rate = 16000
        val minBuf = android.media.AudioRecord.getMinBufferSize(
            rate, android.media.AudioFormat.CHANNEL_IN_MONO, android.media.AudioFormat.ENCODING_PCM_16BIT)
        val rec = try {
            // VOICE_COMMUNICATION：系统回声消除，AI 外放不混进麦克风
            android.media.AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, rate,
                android.media.AudioFormat.CHANNEL_IN_MONO, android.media.AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf, rate))
        } catch (e: Exception) { return }
        if (rec.state != android.media.AudioRecord.STATE_INITIALIZED) { runCatching { rec.release() }; return }
        runCatching {
            if (android.media.audiofx.AcousticEchoCanceler.isAvailable()) {
                echoCanceler = android.media.audiofx.AcousticEchoCanceler.create(rec.audioSessionId)?.apply { enabled = true }
            }
        }
        audioRecord = rec
        rec.startRecording()
        captureJob = scope.launch(Dispatchers.IO) {
            val buf = ByteArray(3200)   // ~100ms @16k16bit
            while (active && audioRecord === rec) {
                val n = rec.read(buf, 0, buf.size)
                if (n <= 0) continue
                val chunk = buf.copyOf(n)
                // RMS 电平（0-1 归一）
                var acc = 0.0
                var idx = 0
                while (idx + 1 < n) {
                    val v = ((chunk[idx + 1].toInt() shl 8) or (chunk[idx].toInt() and 0xFF)).toShort().toDouble() / 32768.0
                    acc += v * v
                    idx += 2
                }
                val level = kotlin.math.min(1.0, kotlin.math.sqrt(acc / maxOf(n / 2, 1)) * 8.0).toFloat()
                withContext(Dispatchers.Main) { processChunk(chunk, level) }
            }
        }
    }

    private fun resetUtterance(sendReset: Boolean) {
        heardSpeech = false
        streamingUtterance = false
        silentMs = 0; bargeTicks = 0; utteranceMs = 0; voicedMs = 0
        preroll.clear()
        if (sendReset) runCatching { webSocket?.send(JSONObject(mapOf("type" to "reset_audio")).toString()) }
    }

    /** 每 ~100ms 一个 PCM 块：电平/VAD/抢话 + 说话中把帧实时发给后端（边说边传）。 */
    private fun processChunk(chunk: ByteArray, level: Float) {
        if (!active) return
        // 暂停（麦克风斜线）＝彻底不听：电平归零、界面不再跳动，也不上传任何帧
        if (paused) { onUserLevel?.invoke(0f); return }
        onUserLevel?.invoke(level)
        if (!connected) return
        if (liveMode) {
            // live 全双工：帧永远上行（AI 说话期间也发——服务端 VAD 据此打断），本地零判停
            runCatching { webSocket?.send(chunk.toByteString()) }
            return
        }
        if (manualCommit) {
            // 手动模式：点按开始→流式上传，点按结束→commit；不做自动静音判定/语音抢话
            if (!aiSpeaking && manualRecording) runCatching { webSocket?.send(chunk.toByteString()) }
            return
        }
        if (aiSpeaking) {
            aiSpeakMs += tickMs
            if (aiSpeakMs >= bargeGraceMs && level >= bargeLevel) {
                bargeTicks++
                if (bargeTicks >= bargeNeeded) bargeIn()
            } else bargeTicks = 0
            return   // AI 说话期间不上传帧（防 AI 声音混进用户话）
        }
        aiSpeakMs = 0
        if (!heardSpeech) noiseFloor = (noiseFloor * 0.92f + level * 0.08f).coerceAtMost(0.5f)
        val speechThresh = noiseFloor + speechMargin
        val silenceThresh = noiseFloor + silenceMargin

        if (streamingUtterance) {
            runCatching { webSocket?.send(chunk.toByteString()) }   // 边说边发
        } else {
            preroll.addLast(chunk)
            if (preroll.size > prerollMax) preroll.removeFirst()
        }

        if (level >= speechThresh) {
            if (!heardSpeech) {
                heardSpeech = true
                streamingUtterance = true
                while (preroll.isNotEmpty()) runCatching { webSocket?.send(preroll.removeFirst().toByteString()) }
            }
            silentMs = 0; utteranceMs += tickMs; voicedMs += tickMs
        } else if (heardSpeech) {
            utteranceMs += tickMs
            if (level <= silenceThresh) silentMs += tickMs else silentMs = 0
            if (silentMs >= silenceThresholdMs) { commitUtterance(); return }
        }
        if (heardSpeech && utteranceMs >= maxUtteranceMs) commitUtterance()
    }




    // ---- 手动触发（常规「点击说话」）与键盘输入 ----

    /** 点按开始说话：AI 正在朗读则先打断；随后帧流式上传直到 endManualUtterance。 */
    fun beginManualUtterance() {
        if (!manualCommit || !connected) return
        if (aiSpeaking) {
            runCatching { webSocket?.send(JSONObject(mapOf("type" to "interrupt")).toString()) }
            suppressAiAudio = true
            runCatching { player?.stop() }; runCatching { player?.release() }; player = null
            aiQueue.clear()
            aiSpeaking = false; onAiSpeaking?.invoke(false); onAiLevel?.invoke(0f)
        }
        runCatching { webSocket?.send(JSONObject(mapOf("type" to "reset_audio")).toString()) }
        manualRecording = true
        if (audioRecord == null) startRecording()
    }

    /** 点按结束：提交本句（用户明确点了发送，跳过噪音门槛）。 */
    fun endManualUtterance() {
        if (!manualCommit || !manualRecording) return
        manualRecording = false
        suppressAiAudio = false
        runCatching {
            webSocket?.send(JSONObject(mapOf(
                "type" to "commit", "format" to "pcm16", "sample_rate" to 16000,
                "guidance_mode" to guidanceMode)).toString())
        }
        scope.launch { onCommitted?.invoke() }
    }

    /** 键盘手工输入：文字直接发后端（跳过 ASR），走同一轮对话/翻译逻辑。 */
    fun sendText(text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        manualRecording = false
        resetUtterance(sendReset = true)
        suppressAiAudio = false
        runCatching { webSocket?.send(JSONObject(mapOf("type" to "text", "text" to trimmed)).toString()) }
        scope.launch { onCommitted?.invoke() }
    }

    private fun bargeIn() {
        runCatching { webSocket?.send(JSONObject(mapOf("type" to "interrupt")).toString()) }
        suppressAiAudio = true   // 被打断的这轮就此作废：其后迟到的 AI 音频全部丢弃，直到下一次 commit
        runCatching { player?.stop() }; runCatching { player?.release() }; player = null
        aiQueue.clear()
        aiSpeaking = false; onAiSpeaking?.invoke(false); onAiLevel?.invoke(0f)
        resetUtterance(sendReset = true)   // 干净开始这次抢话（清后端残留帧）
    }

    private fun commitUtterance() {
        // 噪音门槛：真人声时长太短(<400ms)视为纯噪音——通知后端清掉已发帧，静默回到聆听
        val voicedEnough = heardSpeech && voicedMs >= 400
        if (voicedEnough) {
            runCatching {
                suppressAiAudio = false   // 新一轮开始，恢复接收 AI 音频
                webSocket?.send(JSONObject(mapOf(
                    "type" to "commit", "format" to "pcm16", "sample_rate" to 16000,
                    "guidance_mode" to guidanceMode)).toString())
                scope.launch { onCommitted?.invoke() }
            }
            resetUtterance(sendReset = false)
        } else {
            resetUtterance(sendReset = true)
        }
    }


    // ---- 收 AI 音频并顺序播放 ----

    /** 立即停止 AI 语音播放并清空队列（顶栏喇叭关闭时调用）。 */
    fun stopAiPlayback() {
        runCatching { player?.stop() }; runCatching { player?.release() }; player = null
        aiQueue.clear()
        aiSpeaking = false
        scope.launch { onAiSpeaking?.invoke(false); onAiLevel?.invoke(0f) }
    }

    private fun enqueueAi(data: ByteArray) {
        if (!autoPlayAI) return   // 用户关掉了自动播放：只留字幕
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
                        arr.optJSONObject(i)?.let { m ->
                            Triple(m.optString("speaker", "ai"), m.optString("text"), m.optString("tone"))
                        }
                    }
                    onFreeTalkHistory?.invoke(items)
                }
                startRecording()
            }
            "user_text" -> {
                val words = obj.optJSONArray("words")?.let { arr ->
                    (0 until arr.length()).mapNotNull { i ->
                        arr.optJSONObject(i)?.let { w ->
                            val word = w.optString("word")
                            if (word.isBlank()) null else WordScore(word, w.optDouble("probability", 1.0))
                        }
                    }
                } ?: emptyList()
                onUserText?.invoke(obj.optString("text"), obj.optString("translation"), words, obj.optInt("wpm", 0))
            }
            "terminated" -> {
                // 涉敏感话题：后端已中断会话——提示并整体退出
                val reason = obj.optString("reason").ifBlank { "本次对话已结束" }
                onTerminated?.invoke(reason)
                stop()
            }
            "live_mode" -> {
                // 后端确认轮次形态：enabled=false → 实时通道不可用，降级回本地 VAD/点按
                liveMode = obj.optBoolean("enabled", false)
            }
            "ai_interrupted" -> {
                // live：用户开口打断——立即停播并丢弃本轮残余
                runCatching { player?.stop() }; runCatching { player?.release() }; player = null
                aiQueue.clear(); receivingAudio = false; incoming = java.io.ByteArrayOutputStream()
                aiSpeaking = false; onAiSpeaking?.invoke(false); onAiLevel?.invoke(0f)
            }
            "listening" -> {
                // live 全双工：轮次判定在服务端，没有本地 commit——用服务端 VAD 事件驱动 UI 反馈：
                // 停止说话 = 这句已提交（触发「老师正在思考…」+ 看门狗），否则用户说完毫无动静
                if (obj.has("speaking")) {
                    if (obj.optBoolean("speaking")) onStatus?.invoke("听到了，请继续说…")
                    else { onStatus?.invoke(""); onCommitted?.invoke() }
                }
            }
            "ai_text" -> onAIText?.invoke(obj.optString("text"), obj.optString("translation"), obj.optString("tone"))
            "ai_audio_error" -> onStatus?.invoke("老师的语音没能合成，本句只显示文字")
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
