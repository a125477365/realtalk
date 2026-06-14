package com.example.realtalkad.wechat

import android.content.Context
import com.tencent.mm.opensdk.modelmsg.SendAuth
import com.tencent.mm.opensdk.openapi.IWXAPI
import com.tencent.mm.opensdk.openapi.WXAPIFactory
import kotlinx.coroutines.CompletableDeferred

/**
 * 微信「移动应用」一键登录。
 *
 * 前置条件（必须先在微信开放平台 open.weixin.qq.com 完成）：
 *  1. 创建「移动应用」并通过审核，拿到 AppID，填到 [APP_ID]；
 *  2. 应用签名/包名与本工程一致（applicationId=com.example.realtalkad）；
 *  3. 后端 .env 的 WECHAT_APP_ID/WECHAT_APP_SECRET 填同一个移动应用凭据，
 *     且 WECHAT_AUTH_DEV_MODE=false。
 *
 * 未配置 AppID 或手机未安装微信时，[isAvailable] 返回 false，上层回退到开发模拟登录。
 */
object WeChatAuth {
    // TODO: 替换为你的微信移动应用 AppID（wx 开头）。留空则走开发模拟登录。
    const val APP_ID: String = ""

    private var api: IWXAPI? = null
    // WXEntryActivity 收到授权回调后通过它把 code 交回登录协程
    @Volatile
    var pendingAuth: CompletableDeferred<String>? = null

    fun register(context: Context): IWXAPI? {
        if (APP_ID.isBlank()) return null
        val wxapi = api ?: WXAPIFactory.createWXAPI(context.applicationContext, APP_ID, true).also {
            it.registerApp(APP_ID)
            api = it
        }
        return wxapi
    }

    fun isAvailable(context: Context): Boolean {
        val wxapi = register(context) ?: return false
        return wxapi.isWXAppInstalled
    }

    /** 拉起微信授权，挂起直到回调返回 code；失败抛异常。 */
    suspend fun authorize(context: Context): String {
        val wxapi = register(context) ?: throw IllegalStateException("未配置微信 AppID")
        if (!wxapi.isWXAppInstalled) throw IllegalStateException("未安装微信")
        val deferred = CompletableDeferred<String>()
        pendingAuth = deferred
        val req = SendAuth.Req().apply {
            scope = "snsapi_userinfo"
            state = "realtalk_login"
        }
        wxapi.sendReq(req)
        return deferred.await()
    }
}
