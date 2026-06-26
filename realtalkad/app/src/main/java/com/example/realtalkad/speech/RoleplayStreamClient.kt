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
    var onUserLevel: ((Float) -> Unit)? = null
    var onAiLevel: ((Float) -> Unit)? = null
    var onAiSpeaking: ((Boolean) -> Unit)? = null

    private val wsClient = OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()
    private var webSocket: WebSocket? = null
    private val scope = CoroutineScope(Dispatchers.Main)
    private var guidanceMode = "realtime"
    private var active = false

    private var recorder: MediaRecorder? = null
    private var file: File? = null
    private var meterJob: Job? = null
    private var heardSpeech = false
    private var silentMs = 0L
    private var bargeTicks = 0
    private val tickMs = 100L
    private val silenceThresholdMs = 2000L
    private val speechLevel = 0.12f
    private val bargeLevel = 0.2f
    private val bargeNeeded = 3

    private var aiSpeaking = false
    private var player: MediaPlayer? = null
    private val aiQueue = ArrayDeque<ByteArray>()
    private var incoming = java.io.ByteArrayOutputStream()
    private var receivingAudio = false

    fun start(wsUrl: String, guidanceMode: String) {
        stop()
        this.guidanceMode = guidanceMode
        active = true
        webSocket = wsClient.newWebSocket(Request.Builder().url(wsUrl).build(), listener)
        startRecording()
    }

    fun stop() {
        active = false
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
            rec.setAudioSource(MediaRecorder.AudioSource.MIC)
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
        heardSpeech = false; silentMs = 0; bargeTicks = 0
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
        if (aiSpeaking) {
            if (level >= bargeLevel) {
                bargeTicks++
                if (bargeTicks >= bargeNeeded) bargeIn()
            } else bargeTicks = 0
            return
        }
        if (level >= speechLevel) { heardSpeech = true; silentMs = 0 }
        else if (heardSpeech) {
            silentMs += tickMs
            if (silentMs >= silenceThresholdMs) commitUtterance()
        }
    }

    private fun bargeIn() {
        runCatching { webSocket?.send(JSONObject(mapOf("type" to "interrupt")).toString()) }
        runCatching { player?.stop() }; runCatching { player?.release() }; player = null
        aiQueue.clear()
        aiSpeaking = false; onAiSpeaking?.invoke(false); onAiLevel?.invoke(0f)
        startRecording()
    }

    private fun commitUtterance() {
        runCatching { recorder?.stop() }
        val out = file
        val heard = heardSpeech
        file = null
        if (heard && out != null && out.length() > 1200) {
            runCatching {
                webSocket?.send(out.readBytes().toByteString())
                webSocket?.send(JSONObject(mapOf("type" to "commit", "format" to ".m4a", "guidance_mode" to guidanceMode)).toString())
            }
        }
        out?.delete()
        startRecording()
    }

    // ---- 收 AI 音频并顺序播放 ----

    private fun enqueueAi(data: ByteArray) {
        aiQueue.addLast(data)
        if (player == null) playNextAi()
    }

    private fun playNextAi() {
        val data = aiQueue.removeFirstOrNull()
        if (data == null) { aiSpeaking = false; onAiSpeaking?.invoke(false); onAiLevel?.invoke(0f); return }
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
            scope.launch { if (active) { onError?.invoke("连接已断开"); stop() } }
        }
        override fun onClosing(ws: WebSocket, code: Int, reason: String) {
            scope.launch { if (active && code != 1000) onError?.invoke(reason.ifBlank { "连接关闭" }) }
        }
    }

    private fun handleEvent(text: String) {
        val obj = runCatching { JSONObject(text) }.getOrNull() ?: return
        when (obj.optString("type")) {
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
            "error" -> onError?.invoke(obj.optString("detail").ifBlank { "对话出错" })
        }
    }
}
