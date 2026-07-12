package com.example.realtalkad.speech

import android.content.Context
import android.content.Intent
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.media.audiofx.Visualizer
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/**
 * 真实对话采集：中文连续识别（zh-CN）。
 * Android SpeechRecognizer 单次会话有时长限制，这里在 onResults/onError 后自动重启实现连续采集。
 */
class SpeechCapture(private val context: Context) {
    var isRecording = false
        private set
    var onSegment: ((String) -> Unit)? = null
    var onStateChange: ((Boolean) -> Unit)? = null

    private var recognizer: SpeechRecognizer? = null

    fun start() {
        if (isRecording) return
        if (!SpeechRecognizer.isRecognitionAvailable(context)) return
        isRecording = true
        onStateChange?.invoke(true)
        startSession()
    }

    fun stop() {
        isRecording = false
        recognizer?.destroy()
        recognizer = null
        onStateChange?.invoke(false)
    }

    private fun startSession() {
        recognizer?.destroy()
        recognizer = SpeechRecognizer.createSpeechRecognizer(context).also { r ->
            r.setRecognitionListener(object : RecognitionListener {
                override fun onResults(results: Bundle) {
                    results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()
                        ?.takeIf { it.isNotBlank() }
                        ?.let { onSegment?.invoke(it) }
                    if (isRecording) startSession()
                }

                override fun onError(error: Int) {
                    if (isRecording) startSession()
                }

                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onPartialResults(partialResults: Bundle?) {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
            r.startListening(intent("zh-CN"))
        }
    }

    private fun intent(language: String) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
    }
}

/**
 * 口语对练：录这一句音频交后端识别+评分（不再端侧 ASR，更宽容、可发音纠正）。
 * - 沉浸式（autoSubmit=true）：能量 VAD，静音到阈值自动提交。
 * - 手工触发式（autoSubmit=false）：不自动提交，由用户松手 stopAndEmit / 滑动 cancel。
 * 公开接口与原先一致；区别是「说完一句」交付音频文件（onAudioFile）而非文本。
 */
class PracticeSpeech(private val context: Context) {
    var isListening = false
        private set
    var onPartial: ((String) -> Unit)? = null
    var onAudioFile: ((File) -> Unit)? = null
    var onStateChange: ((Boolean) -> Unit)? = null
    var onLevel: ((Float) -> Unit)? = null
    /// 兼容旧调用点：识别已移到后端并按场景目标句自动偏置，端侧无需再传。
    var expectedPhrases: List<String> = emptyList()

    private var recorder: MediaRecorder? = null
    private var file: File? = null
    private var meterJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.Main)
    private var autoSubmit = true
    private var heardSpeech = false
    private var silentMs = 0L
    private val tickMs = 100L
    private val silenceThresholdMs = 2600L
    private val speechLevel = 0.12f

    fun start(autoSubmit: Boolean = true) {
        if (isListening) return
        this.autoSubmit = autoSubmit
        heardSpeech = false
        silentMs = 0
        val out = File(context.cacheDir, "rt-utt-${UUID.randomUUID()}.m4a")
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
            runCatching { rec.release() }
            out.delete()
            return
        }
        recorder = rec
        file = out
        isListening = true
        onStateChange?.invoke(true)
        meterJob = scope.launch {
            while (isListening) {
                delay(tickMs)
                meterTick()
            }
        }
    }

    private fun meterTick() {
        val r = recorder ?: return
        val amp = runCatching { r.maxAmplitude }.getOrDefault(0)
        val level = (amp / 12000f).coerceIn(0f, 1f)
        onLevel?.invoke(level)
        if (level >= speechLevel) {
            heardSpeech = true
            silentMs = 0
        } else if (heardSpeech) {
            silentMs += tickMs
            if (autoSubmit && silentMs >= silenceThresholdMs) stopAndEmit()
        }
    }

    /** 手工触发式：松手发送（也是沉浸式静音自动提交的入口）。 */
    fun stopAndEmit() {
        val out = file
        val heard = heardSpeech
        stop()
        if (heard && out != null && out.length() > 1200) {
            onAudioFile?.invoke(out)   // 上层负责用完删除
        } else {
            out?.delete()
        }
    }

    /** 手工触发式：滑到取消区，丢弃本次。 */
    fun cancel() {
        val out = file
        stop()
        out?.delete()
    }

    fun stop() {
        isListening = false
        meterJob?.cancel()
        meterJob = null
        runCatching { recorder?.stop() }
        runCatching { recorder?.release() }
        recorder = null
        file = null
        onPartial?.invoke("")
        onLevel?.invoke(0f)
        onStateChange?.invoke(false)
    }
}

/** AI 台词朗读。优先后端 TTS（可选音色），后端不可用回退本机 TTS，完成后回调驱动连续对话。 */
class VoicePlayer(private val context: Context) {
    var isSpeaking = false
        private set
    var onStateChange: ((Boolean) -> Unit)? = null
    var onLevel: ((Float) -> Unit)? = null

    /** 由 AppViewModel 注入：给定(文本, 是否走缓存)返回后端合成音频（调 /tts/speak）。指导内容传 cache=false。 */
    var audioProvider: (suspend (String, Boolean) -> ByteArray?)? = null
    var scope: CoroutineScope? = null

    private var pendingCompletion: (() -> Unit)? = null
    private var visualizer: Visualizer? = null
    private var player: MediaPlayer? = null
    private var fetchJob: Job? = null

    // 只用后端语音服务，普通朗读与实时对话使用用户选择的同一声音。
    fun speak(text: String, cache: Boolean = true, completion: (() -> Unit)? = null) {
        if (text.isBlank()) { completion?.invoke(); return }
        stopPlayback()
        val provider = audioProvider
        val sc = scope
        if (provider != null && sc != null) {
            isSpeaking = true
            onStateChange?.invoke(true)
            fetchJob = sc.launch {
                val bytes = runCatching { provider(text, cache) }.getOrNull()
                if (bytes != null && playBytes(bytes, completion)) return@launch
                withContext(Dispatchers.Main) { skip(completion) }   // 后端音频不可用 → 跳过
            }
        } else {
            skip(completion)
        }
    }

    private fun skip(completion: (() -> Unit)?) {
        isSpeaking = false
        stopMetering()
        onStateChange?.invoke(false)
        completion?.invoke()
    }

    private fun playBytes(bytes: ByteArray, completion: (() -> Unit)?): Boolean {
        return try {
            val f = File(context.cacheDir, "rt-tts-${UUID.randomUUID()}.mp3")
            f.writeBytes(bytes)
            val mp = MediaPlayer()
            mp.setDataSource(f.absolutePath)
            mp.setOnCompletionListener {
                isSpeaking = false
                stopMetering()
                onStateChange?.invoke(false)
                runCatching { it.release() }
                player = null
                f.delete()
                pendingCompletion = null
                completion?.invoke()
            }
            mp.setOnErrorListener { _, _, _ -> f.delete(); false }
            mp.prepare()
            player = mp
            pendingCompletion = completion
            startMetering()
            mp.start()
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun stopPlayback() {
        fetchJob?.cancel()
        fetchJob = null
        runCatching { player?.stop() }
        runCatching { player?.release() }
        player = null
    }

    fun stop() {
        pendingCompletion = null
        stopPlayback()
        stopMetering()
        isSpeaking = false
        onStateChange?.invoke(false)
    }

    private fun startMetering() {
        runCatching {
            releaseVisualizer()
            // session 0 = 全局输出混音；需要 RECORD_AUDIO 权限（已申请）。
            visualizer = Visualizer(0).apply {
                captureSize = Visualizer.getCaptureSizeRange()[1]
                setDataCaptureListener(
                    object : Visualizer.OnDataCaptureListener {
                        override fun onWaveFormDataCapture(v: Visualizer?, waveform: ByteArray?, samplingRate: Int) {
                            if (waveform == null || waveform.isEmpty()) return
                            var sum = 0.0
                            for (b in waveform) {
                                val centered = (b.toInt() and 0xFF) - 128
                                sum += (centered * centered).toDouble()
                            }
                            val rms = kotlin.math.sqrt(sum / waveform.size)
                            onLevel?.invoke((rms / 48.0).coerceIn(0.0, 1.0).toFloat())
                        }

                        override fun onFftDataCapture(v: Visualizer?, fft: ByteArray?, samplingRate: Int) {}
                    },
                    Visualizer.getMaxCaptureRate() / 2,
                    true,
                    false,
                )
                enabled = true
            }
        }
    }

    private fun stopMetering() {
        releaseVisualizer()
        onLevel?.invoke(0f)
    }

    private fun releaseVisualizer() {
        visualizer?.let { v ->
            runCatching { v.enabled = false }
            runCatching { v.release() }
        }
        visualizer = null
    }
}
