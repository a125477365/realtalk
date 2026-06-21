package com.example.realtalkad.speech

import android.content.Context
import android.content.Intent
import android.media.audiofx.Visualizer
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale
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
 * 口语对练：英文识别（en-US），带实时字幕。
 * - 沉浸式（autoSubmit=true）：拉长静音判定，停顿思考不算说完；静音到阈值才自动提交。
 * - 手工触发式（autoSubmit=false）：不自动提交，允许停顿（识别段落累积），由用户松手时提交/取消。
 */
class PracticeSpeech(private val context: Context) {
    var isListening = false
        private set
    var onPartial: ((String) -> Unit)? = null
    var onUtterance: ((String) -> Unit)? = null
    var onStateChange: ((Boolean) -> Unit)? = null
    var onLevel: ((Float) -> Unit)? = null

    private var recognizer: SpeechRecognizer? = null
    private var lastPartial = ""
    private var accumulated = ""
    private var manualMode = false

    private fun combined(): String = ("$accumulated $lastPartial").trim()
    private fun appendSeg(seg: String) {
        accumulated = if (accumulated.isBlank()) seg else "$accumulated $seg"
    }

    fun start(autoSubmit: Boolean = true) {
        if (isListening) return
        if (!SpeechRecognizer.isRecognitionAvailable(context)) return
        manualMode = !autoSubmit
        accumulated = ""
        lastPartial = ""
        isListening = true
        onStateChange?.invoke(true)
        startSession()
    }

    private fun startSession() {
        recognizer?.destroy()
        recognizer = SpeechRecognizer.createSpeechRecognizer(context).also { r ->
            r.setRecognitionListener(object : RecognitionListener {
                override fun onPartialResults(partialResults: Bundle?) {
                    partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()
                        ?.let { lastPartial = it; onPartial?.invoke(combined()) }
                }

                override fun onResults(results: Bundle) {
                    val text = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull() ?: lastPartial
                    if (manualMode) {
                        if (text.isNotBlank()) appendSeg(text)
                        lastPartial = ""
                        onPartial?.invoke(combined())
                        if (isListening) startSession()  // 继续听，允许停顿
                    } else {
                        stop()
                        text.takeIf { it.isNotBlank() }?.let { onUtterance?.invoke(it) }
                    }
                }

                override fun onError(error: Int) {
                    if (manualMode) {
                        if (isListening) startSession()  // 静音/超时就重启继续听
                    } else {
                        val pending = lastPartial
                        stop()
                        pending.takeIf { it.isNotBlank() }?.let { onUtterance?.invoke(it) }
                    }
                }

                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {
                    onLevel?.invoke(((rmsdB + 2f) / 12f).coerceIn(0f, 1f))
                }
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
            r.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-US")
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                // 拉长静音判定，给思考停顿留时间（参考主流口语 App）
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 2500L)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 2500L)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 1500L)
            })
        }
    }

    /** 手工触发式：松手发送，提交累积文本。 */
    fun stopAndEmit() {
        val text = combined()
        stop()
        text.takeIf { it.isNotBlank() }?.let { onUtterance?.invoke(it) }
    }

    /** 手工触发式：滑到取消区，丢弃本次。 */
    fun cancel() = stop()

    fun stop() {
        isListening = false
        manualMode = false
        accumulated = ""
        lastPartial = ""
        onPartial?.invoke("")
        onLevel?.invoke(0f)
        recognizer?.destroy()
        recognizer = null
        onStateChange?.invoke(false)
    }
}

/** AI 台词朗读（英文 TTS），完成后回调以驱动连续对话。 */
class VoicePlayer(context: Context) {
    var isSpeaking = false
        private set
    var onStateChange: ((Boolean) -> Unit)? = null

    /**
     * AI 朗读时的实时输出电平（0..1）。用 [Visualizer] 监听系统输出混音的真实波形，
     * 因此提示圈是跟着 AI 实际播放音量跳动，而不是固定正弦动画。
     */
    var onLevel: ((Float) -> Unit)? = null

    private var pendingCompletion: (() -> Unit)? = null
    private var visualizer: Visualizer? = null
    private val tts = TextToSpeech(context) { status ->
        if (status == TextToSpeech.SUCCESS) ready = true
    }
    private var ready = false

    init {
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) = finish()
            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) = finish()

            private fun finish() {
                isSpeaking = false
                stopMetering()
                onStateChange?.invoke(false)
                pendingCompletion?.let { done -> pendingCompletion = null; done() }
            }
        })
    }

    fun speak(text: String, completion: (() -> Unit)? = null) {
        if (!ready || text.isBlank()) { completion?.invoke(); return }
        // 含中文（如纠正/评分建议）用中文 TTS，否则英文，避免中文被英文引擎读乱（item 3）
        val hasHan = text.any { it.code in 0x4E00..0x9FFF }
        tts.language = if (hasHan) Locale.CHINESE else Locale.US
        tts.setSpeechRate(0.92f)   // 稍放慢，减少吞字/含糊，提升清晰度
        tts.setPitch(1.0f)
        isSpeaking = true
        onStateChange?.invoke(true)
        startMetering()
        pendingCompletion = completion
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, UUID.randomUUID().toString())
    }

    fun stop() {
        pendingCompletion = null
        tts.stop()
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
