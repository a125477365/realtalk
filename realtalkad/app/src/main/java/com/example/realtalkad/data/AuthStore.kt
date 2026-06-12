package com.example.realtalkad.data

import android.content.Context
import java.util.UUID

/** Token / 服务器地址 / 微信 dev 登录种子的本地存储。 */
class AuthStore(context: Context) {
    private val prefs = context.getSharedPreferences("realtalk", Context.MODE_PRIVATE)

    var token: String?
        get() = prefs.getString("token", null)
        set(value) = prefs.edit().putString("token", value).apply()

    var baseUrl: String
        get() = prefs.getString("base_url", DEFAULT_BASE_URL) ?: DEFAULT_BASE_URL
        set(value) = prefs.edit().putString("base_url", value.trim().trimEnd('/')).apply()

    /** 开发模式微信登录：同一设备稳定复用一个 code，对应同一个账号 */
    val devWeChatCode: String
        get() {
            val existing = prefs.getString("dev_wechat_code", null)
            if (existing != null) return existing
            val created = "android-dev-${UUID.randomUUID()}"
            prefs.edit().putString("dev_wechat_code", created).apply()
            return created
        }

    fun clear() {
        prefs.edit().remove("token").apply()
    }

    companion object {
        const val DEFAULT_BASE_URL = "http://192.168.6.3:8000"
    }
}
