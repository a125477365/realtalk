package com.example.realtalkad.speech

import android.content.Context
import android.content.Intent
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

/** 口语对练：英文识别（en-US），带实时字幕，静音自动提交。 */
class PracticeSpeech(private val context: Context) {
    var isListening = false
        private set
    var onPartial: ((String) -> Unit)? = null
    var onUtterance: ((String) -> Unit)? = null
    var onStateChange: ((Boolean) -> Unit)? = null

    private var recognizer: SpeechRecognizer? = null
    private var lastPartial = ""

    fun start() {
        if (isListening) return
        if (!SpeechRecognizer.isRecognitionAvailable(context)) return
        isListening = true
        lastPartial = ""
        onStateChange?.invoke(true)
        recognizer = SpeechRecognizer.createSpeechRecognizer(context).also { r ->
            r.setRecognitionListener(object : RecognitionListener {
                override fun onPartialResults(partialResults: Bundle?) {
                    partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull()
                        ?.let { lastPartial = it; onPartial?.invoke(it) }
                }

                override fun onResults(results: Bundle) {
                    val text = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                        ?.firstOrNull() ?: lastPartial
                    stop()
                    text.takeIf { it.isNotBlank() }?.let { onUtterance?.invoke(it) }
                }

                override fun onError(error: Int) {
                    val pending = lastPartial
                    stop()
                    pending.takeIf { it.isNotBlank() }?.let { onUtterance?.invoke(it) }
                }

                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
            r.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "en-US")
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            })
        }
    }

    fun stop() {
        isListening = false
        onPartial?.invoke("")
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

    private var pendingCompletion: (() -> Unit)? = null
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
                onStateChange?.invoke(false)
                pendingCompletion?.let { done -> pendingCompletion = null; done() }
            }
        })
    }

    fun speak(text: String, completion: (() -> Unit)? = null) {
        if (!ready || text.isBlank()) { completion?.invoke(); return }
        tts.language = Locale.US
        isSpeaking = true
        onStateChange?.invoke(true)
        pendingCompletion = completion
        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, UUID.randomUUID().toString())
    }

    fun stop() {
        pendingCompletion = null
        tts.stop()
        isSpeaking = false
        onStateChange?.invoke(false)
    }
}
