package com.example.realtalkad.speech

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.util.Base64
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.net.URLEncoder
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.math.sqrt

/**
 * 高级会员「实时语音大模型」对练客户端（需求第 4 项），与 iOS RealtimeVoiceManager 等价。
 *
 * 通过 WebSocket 连接后端 `/roleplay/voice`，后端只做透明转发并注入场景台词/护栏：
 * - AudioRecord 采集麦克风 24kHz/PCM16 → base64 走 `input_audio_buffer.append` 上行；
 * - 接收 `response.audio.delta`（base64 PCM16）用 AudioTrack 实时播放 AI 语音；
 * - 接收转写事件做字幕；用户开口（server VAD `speech_started`）即冲掉待播 AI 音频实现自然抢话；
 * - 结束时发送 `realtalk.end`，等待后端回传 `realtalk.review`（评分 + 中文分析）。
 *
 * 后端不处理音频内容，护栏（只做口语练习、按场景台词、不越界、不涉政/敏感）由服务端 session 指令强制。
 */
class RealtimeVoiceClient(private val context: Context) {

    enum class Phase { IDLE, CONNECTING, ACTIVE, ENDING, ENDED, ERROR }

    data class Line(val role: String, val text: String)   // role: "user" / "ai"
    data class Review(val score: Int, val analysis: String)

    val phase = MutableStateFlow(Phase.IDLE)
    val transcript = MutableStateFlow<List<Line>>(emptyList())
    val guidanceText = MutableStateFlow("")   // 实时指导：后端对每句话音生成的简短中文提示
    val review = MutableStateFlow<Review?>(null)
    val statusText = MutableStateFlow("")
    val inputLevel = MutableStateFlow(0f)
    val aiSpeaking = MutableStateFlow(false)

    private val wsClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .pingInterval(20, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS)
        .build()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private var webSocket: WebSocket? = null
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var captureThread: Thread? = null
    @Volatile private var capturing = false
    private var endTimeoutJob: Job? = null
    private var scenarioTitle = ""
    // 断线重连：连接可恢复、字幕(transcript)保留；但实时模型 provider 侧有状态，重连后模型上下文会重置（实时语义固有）
    private var rtBaseUrl = ""
    private var rtToken = ""
    private var rtSessionId = ""
    private var reconnectAttempts = 0
    private val maxReconnect = 3
    private var reconnectJob: Job? = null

    // ---- 生命周期 ----

    fun start(baseUrl: String, token: String, sessionId: String, title: String) {
        if (phase.value !in listOf(Phase.IDLE, Phase.ENDED, Phase.ERROR)) return
        reset()
        scenarioTitle = title
        rtBaseUrl = baseUrl; rtToken = token; rtSessionId = sessionId
        reconnectAttempts = 0
        phase.value = Phase.CONNECTING
        statusText.value = "正在连接语音模型…"

        val wsUrl = buildWsUrl(baseUrl, token, sessionId)
        if (wsUrl == null) { fail("服务地址无效"); return }
        webSocket = wsClient.newWebSocket(Request.Builder().url(wsUrl).build(), listener)
    }

    /** 结束并评分：停麦、通知后端结束，等待 realtalk.review 回传。 */
    fun end() {
        if (phase.value != Phase.ACTIVE && phase.value != Phase.CONNECTING) return
        reconnectJob?.cancel(); reconnectJob = null
        phase.value = Phase.ENDING
        statusText.value = "正在生成评分与建议…"
        stopCapture()
        send("{\"type\":\"realtalk.end\"}")
        scheduleEndTimeout()
    }

    /** 直接退出（不等待评分）。 */
    fun cancel() {
        reconnectJob?.cancel(); reconnectJob = null
        endTimeoutJob?.cancel(); endTimeoutJob = null
        teardownAudio()
        runCatching { webSocket?.close(1000, null) }
        webSocket = null
        if (!isEnded()) phase.value = Phase.ENDED
    }

    private fun isEnded() = phase.value == Phase.ENDED || phase.value == Phase.ERROR

    private fun reset() {
        transcript.value = emptyList()
        review.value = null
        inputLevel.value = 0f
        aiSpeaking.value = false
    }

    private fun fail(message: String) {
        teardownAudio()
        runCatching { webSocket?.close(1000, null) }
        webSocket = null
        phase.value = Phase.ERROR
        statusText.value = message
    }

    // ---- WebSocket ----

    private val listener = object : WebSocketListener() {
        override fun onOpen(ws: WebSocket, response: Response) {
            scope.launch {
                if (phase.value == Phase.CONNECTING) {
                    phase.value = Phase.ACTIVE
                    statusText.value = scenarioTitle
                }
                if (!capturing) { startPlayback(); startCapture() }   // 首次起音频；重连时音频已在跑，避免重复 AudioTrack
                if (reconnectAttempts > 0) statusText.value = scenarioTitle
                reconnectAttempts = 0
                send("{\"type\":\"response.create\"}")   // 让 AI 按场景台词先开口/续话
            }
        }

        override fun onMessage(ws: WebSocket, text: String) {
            scope.launch { handleEvent(text) }
        }

        override fun onClosing(ws: WebSocket, code: Int, reason: String) {
            runCatching { ws.close(1000, null) }
            scope.launch { handleSocketClosed(closeMessage(code, reason)) }
        }

        override fun onClosed(ws: WebSocket, code: Int, reason: String) {
            scope.launch { handleSocketClosed(closeMessage(code, reason)) }
        }

        override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) {
            scope.launch { handleSocketClosed(t.message) }
        }
    }

    private fun send(payload: String) {
        runCatching { webSocket?.send(payload) }
    }

    private fun handleEvent(text: String) {
        val obj = runCatching { JSONObject(text) }.getOrNull() ?: return
        when (obj.optString("type")) {
            "response.audio.delta" -> {
                val b64 = obj.optString("delta")
                if (b64.isNotEmpty()) {
                    aiSpeaking.value = true
                    runCatching { playAudio(Base64.decode(b64, Base64.DEFAULT)) }
                }
            }
            "input_audio_buffer.speech_started" -> flushPlayback()
            "response.audio.done", "response.done", "output_audio_buffer.stopped" -> aiSpeaking.value = false
            "conversation.item.input_audio_transcription.completed" -> appendLine("user", obj.optString("transcript"))
            "response.audio_transcript.done" -> appendLine("ai", obj.optString("transcript"))
            "realtalk.guidance" -> {
                obj.optString("text").takeIf { it.isNotBlank() }?.let { guidanceText.value = it }
            }
            "realtalk.review" -> {
                review.value = Review(obj.optInt("score", 0), obj.optString("analysis"))
                finishWithReview()
            }
            "error" -> obj.optJSONObject("error")?.optString("message")?.takeIf { it.isNotBlank() }
                ?.let { statusText.value = it }
        }
    }

    private fun appendLine(role: String, raw: String) {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return
        val current = transcript.value
        val last = current.lastOrNull()
        if (last?.role == role && last.text == trimmed) return
        transcript.value = current + Line(role, trimmed)
    }

    private fun scheduleEndTimeout() {
        endTimeoutJob?.cancel()
        endTimeoutJob = scope.launch {
            delay(15_000)
            if (!isEnded()) {
                if (review.value == null) statusText.value = "评分超时，已结束本轮"
                finishWithReview()
            }
        }
    }

    private fun finishWithReview() {
        endTimeoutJob?.cancel(); endTimeoutJob = null
        teardownAudio()
        runCatching { webSocket?.close(1000, null) }
        webSocket = null
        phase.value = Phase.ENDED
        if (statusText.value.isBlank() || statusText.value == "正在生成评分与建议…") {
            statusText.value = "本轮已结束"
        }
    }

    private fun handleSocketClosed(reason: String?) {
        if (isEnded()) return
        if (phase.value == Phase.ENDING) { finishWithReview(); return }
        // 对练中网络抖动：自动重连（保留音频与字幕），重试用尽才报错
        if (phase.value == Phase.ACTIVE && reconnectAttempts < maxReconnect) {
            scheduleReconnect(); return
        }
        teardownAudio()
        webSocket = null
        phase.value = Phase.ERROR
        statusText.value = reason?.takeIf { it.isNotBlank() } ?: "语音连接已断开"
    }

    private fun scheduleReconnect() {
        runCatching { webSocket?.cancel() }
        webSocket = null
        reconnectAttempts++
        statusText.value = "网络不稳，正在重连…"
        val delayMs = minOf(6000L, (1000L shl (reconnectAttempts - 1)))
        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            delay(delayMs)
            if (phase.value != Phase.ACTIVE) return@launch
            val wsUrl = buildWsUrl(rtBaseUrl, rtToken, rtSessionId)
            if (wsUrl == null) { fail("重连失败，请重试"); return@launch }
            webSocket = wsClient.newWebSocket(Request.Builder().url(wsUrl).build(), listener)
        }
    }

    private fun buildWsUrl(baseUrl: String, token: String, sessionId: String): String? {
        val trimmed = baseUrl.trim().trimEnd('/')
        val wsBase = when {
            trimmed.startsWith("https://") -> "wss://" + trimmed.removePrefix("https://")
            trimmed.startsWith("http://") -> "ws://" + trimmed.removePrefix("http://")
            else -> return null
        }
        val t = URLEncoder.encode(token, "UTF-8")
        val s = URLEncoder.encode(sessionId, "UTF-8")
        return "$wsBase/roleplay/voice?token=$t&session_id=$s"
    }

    private fun closeMessage(code: Int, reason: String): String? = when {
        reason.isNotBlank() -> reason
        code == 4401 -> "登录已失效，请重新登录"
        code == 4404 -> "场景练习不存在"
        code == 4503 -> "语音大模型未配置，请联系管理员"
        else -> null
    }

    // ---- 音频采集 / 播放 ----

    private fun startCapture() {
        if (capturing) return
        val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val bufSize = maxOf(minBuf, 4096)
        val recorder = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,   // 启用回声消除，避免 AI 声被回采
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufSize,
            )
        } catch (_: SecurityException) {
            fail("需要麦克风权限才能进行语音对练"); return
        } catch (_: IllegalArgumentException) {
            fail("麦克风初始化失败"); return
        }
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release(); fail("麦克风不可用"); return
        }
        audioRecord = recorder
        capturing = true
        recorder.startRecording()
        captureThread = thread(name = "rt-voice-capture") {
            val buffer = ByteArray(bufSize)
            while (capturing) {
                val read = recorder.read(buffer, 0, buffer.size)
                if (read > 0) {
                    val slice = if (read == buffer.size) buffer else buffer.copyOf(read)
                    val b64 = Base64.encodeToString(slice, Base64.NO_WRAP)
                    send("{\"type\":\"input_audio_buffer.append\",\"audio\":\"$b64\"}")
                    inputLevel.value = rms(slice, read)
                } else if (read < 0) {
                    break
                }
            }
        }
    }

    private fun stopCapture() {
        capturing = false
        runCatching { captureThread?.join(300) }
        captureThread = null
        runCatching { audioRecord?.stop() }
        runCatching { audioRecord?.release() }
        audioRecord = null
        inputLevel.value = 0f
    }

    private fun startPlayback() {
        val minBuf = AudioTrack.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(SAMPLE_RATE)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setBufferSizeInBytes(maxOf(minBuf, 8192))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        runCatching { track.play() }
        audioTrack = track
    }

    private fun playAudio(bytes: ByteArray) {
        val track = audioTrack ?: return
        runCatching { track.write(bytes, 0, bytes.size) }
    }

    /** 用户开口即清空待播 AI 音频，实现自然打断。 */
    private fun flushPlayback() {
        audioTrack?.let { track ->
            runCatching { track.pause(); track.flush(); track.play() }
        }
        aiSpeaking.value = false
    }

    private fun teardownAudio() {
        stopCapture()
        audioTrack?.let { track ->
            runCatching { track.pause() }
            runCatching { track.flush() }
            runCatching { track.stop() }
            runCatching { track.release() }
        }
        audioTrack = null
        aiSpeaking.value = false
    }

    private fun rms(bytes: ByteArray, length: Int): Float {
        val samples = length / 2
        if (samples <= 0) return 0f
        var sum = 0.0
        var i = 0
        while (i + 1 < length) {
            val sample = (bytes[i].toInt() and 0xFF) or (bytes[i + 1].toInt() shl 8)
            sum += (sample * sample).toDouble()
            i += 2
        }
        val rms = sqrt(sum / samples)
        return (rms / 8000.0).coerceIn(0.0, 1.0).toFloat()
    }

    companion object {
        private const val SAMPLE_RATE = 24_000
    }
}
