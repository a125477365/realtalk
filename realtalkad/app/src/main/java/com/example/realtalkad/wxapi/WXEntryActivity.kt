package com.example.realtalkad.wxapi

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.example.realtalkad.wechat.WeChatAuth
import com.tencent.mm.opensdk.constants.ConstantsAPI
import com.tencent.mm.opensdk.modelbase.BaseReq
import com.tencent.mm.opensdk.modelbase.BaseResp
import com.tencent.mm.opensdk.modelmsg.SendAuth
import com.tencent.mm.opensdk.openapi.IWXAPIEventHandler

/**
 * 微信回调入口。包名必须是 <applicationId>.wxapi.WXEntryActivity（微信硬性要求）。
 * 收到授权结果后把 code 交回 [WeChatAuth.pendingAuth]。
 */
class WXEntryActivity : Activity(), IWXAPIEventHandler {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WeChatAuth.register(this)?.handleIntent(intent, this) ?: finish()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        WeChatAuth.register(this)?.handleIntent(intent, this)
    }

    override fun onReq(req: BaseReq) {}

    override fun onResp(resp: BaseResp) {
        val pending = WeChatAuth.pendingAuth
        WeChatAuth.pendingAuth = null
        if (resp is SendAuth.Resp && resp.type == ConstantsAPI.COMMAND_SENDAUTH) {
            when (resp.errCode) {
                BaseResp.ErrCode.ERR_OK -> pending?.complete(resp.code ?: "")
                BaseResp.ErrCode.ERR_USER_CANCEL -> pending?.completeExceptionally(Exception("已取消微信登录"))
                else -> pending?.completeExceptionally(Exception("微信登录失败（${resp.errCode}）"))
            }
        }
        finish()
    }
}
