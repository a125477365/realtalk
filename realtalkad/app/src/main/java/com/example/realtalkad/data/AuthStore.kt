package com.example.realtalkad.data

import android.content.Context
import java.util.UUID

/** Token / 服务器地址 / 微信 dev 登录种子的本地存储。 */
class AuthStore(context: Context) {
    private val prefs = context.getSharedPreferences("realtalk", Context.MODE_PRIVATE)

    var token: String?
        get() = prefs.getString("token", null)
        set(value) = prefs.edit().putString("token", value).apply()

    var refreshToken: String?
        get() = prefs.getString("refresh_token", null)
        set(value) = prefs.edit().putString("refresh_token", value).apply()

    var baseUrl: String
        get() = prefs.getString("base_url", DEFAULT_BASE_URL) ?: DEFAULT_BASE_URL
        set(value) = prefs.edit().putString("base_url", value.trim().trimEnd('/')).apply()

    var showSubtitles: Boolean
        get() = prefs.getBoolean("show_subtitles", true)
        set(value) = prefs.edit().putBoolean("show_subtitles", value).apply()

    // 指导方式偏好：ask / realtime / final（默认 ask=每次询问）。对话中不可切换。
    var guidancePreference: String
        get() = prefs.getString("guidance_pref", "ask") ?: "ask"
        set(value) = prefs.edit().putString("guidance_pref", value).apply()

    // 对话方式偏好：ask / immersive / manual（默认 ask）。
    var conversationPreference: String
        get() = prefs.getString("conversation_pref", "ask") ?: "ask"
        set(value) = prefs.edit().putString("conversation_pref", value).apply()

    // 高级会员：沉浸式对话时改用实时语音大模型直接对话（默认关闭=文本式对练）。
    var voiceLLMPreference: Boolean
        get() = prefs.getBoolean("voice_llm_pref", false)
        set(value) = prefs.edit().putBoolean("voice_llm_pref", value).apply()

    var autoSpeakAI: Boolean
        get() = prefs.getBoolean("auto_speak_ai", true)
        set(value) = prefs.edit().putBoolean("auto_speak_ai", value).apply()

    var continuousVoice: Boolean
        get() = prefs.getBoolean("continuous_voice", true)
        set(value) = prefs.edit().putBoolean("continuous_voice", value).apply()

    var fontScale: Float
        get() = prefs.getFloat("font_scale", 1f).coerceIn(0.85f, 1.35f)
        set(value) = prefs.edit().putFloat("font_scale", value.coerceIn(0.85f, 1.35f)).apply()

    var autoCaptureEnabled: Boolean
        get() = prefs.getBoolean("auto_capture_enabled", false)
        set(value) = prefs.edit().putBoolean("auto_capture_enabled", value).apply()

    var autoCaptureStart: String
        get() = prefs.getString("auto_capture_start", "09:00") ?: "09:00"
        set(value) = prefs.edit().putString("auto_capture_start", value).apply()

    var autoCaptureEnd: String
        get() = prefs.getString("auto_capture_end", "18:00") ?: "18:00"
        set(value) = prefs.edit().putString("auto_capture_end", value).apply()

    // 多个自动采集时段，存为 "HH:mm-HH:mm;HH:mm-HH:mm"。空则迁移自旧单时段。
    var captureWindows: String
        get() = prefs.getString("capture_windows", "$autoCaptureStart-$autoCaptureEnd")
            ?: "$autoCaptureStart-$autoCaptureEnd"
        set(value) = prefs.edit().putString("capture_windows", value).apply()

    // 外观主题：system / light / dark
    var appearance: String
        get() = prefs.getString("appearance", "system") ?: "system"
        set(value) = prefs.edit().putString("appearance", value).apply()

    /** 开发模式微信登录：同一设备稳定复用一个 code，对应同一个账号 */
    val devWeChatCode: String
        get() {
            val existing = prefs.getString("dev_wechat_code", null)
            if (existing != null) return existing
            val created = "android-dev-${UUID.randomUUID()}"
            prefs.edit().putString("dev_wechat_code", created).apply()
            return created
        }

    /** 本机唯一安全编号：用于单设备登录绑定，持久化在本地。 */
    val deviceId: String
        get() {
            val existing = prefs.getString("device_id", null)
            if (existing != null) return existing
            val created = "android-${UUID.randomUUID()}"
            prefs.edit().putString("device_id", created).apply()
            return created
        }

    fun clear() {
        prefs.edit().remove("token").remove("refresh_token").apply()
    }

    companion object {
        const val DEFAULT_BASE_URL = "http://192.168.6.3:8000"
    }
}
