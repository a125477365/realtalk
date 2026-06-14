import Foundation

/// 微信「移动应用」一键登录。
///
/// 启用步骤（缺一不可，且需微信开放平台审核通过）：
///  1. open.weixin.qq.com 创建「移动应用」，拿到 AppID，填到 `AppConfig.wechatAppID`；
///     Bundle ID 与 Universal Link 必须与开放平台后台一致。
///  2. Xcode 用 Swift Package Manager 添加微信 OpenSDK
///     （https://github.com/wechat-open/WechatOpenSDK-XCFramework 或腾讯官方 pod
///     `WechatOpenSDK-XCFramework`），使 `import WechatOpenSDK` 可用。
///  3. Info.plist 已预置 URL Scheme（wx<AppID>）与 LSApplicationQueriesSchemes；
///     把占位的 `wxYOURAPPID` 改成真实 AppID。
///  4. 后端 .env 填同一移动应用的 WECHAT_APP_ID/WECHAT_APP_SECRET，且
///     WECHAT_AUTH_DEV_MODE=false。
///
/// 未集成 SDK（canImport 失败）或未配置 AppID 时，`isAvailable` 为 false，
/// 上层 `AuthStore.loginWithWeChat` 自动回退到开发模拟登录，保证 App 始终可用。
@MainActor
final class WeChatAuthManager: NSObject {
    static let shared = WeChatAuthManager()

    private var continuation: CheckedContinuation<String, Error>?

    var isAvailable: Bool {
        #if canImport(WechatOpenSDK)
        return AppConfig.wechatAppID.isEmpty == false && WXApi.isWXAppInstalled()
        #else
        return false
        #endif
    }

    /// App 启动时调用，注册微信 SDK。
    func registerIfNeeded() {
        #if canImport(WechatOpenSDK)
        guard AppConfig.wechatAppID.isEmpty == false else { return }
        WXApi.registerApp(AppConfig.wechatAppID, universalLink: AppConfig.wechatUniversalLink)
        #endif
    }

    /// 处理来自微信的回调（在 App 的 onOpenURL / continueUserActivity 中调用）。
    @discardableResult
    func handleOpen(url: URL) -> Bool {
        #if canImport(WechatOpenSDK)
        return WXApi.handleOpen(url, delegate: self)
        #else
        return false
        #endif
    }

    @discardableResult
    func handleUniversalLink(_ userActivity: NSUserActivity) -> Bool {
        #if canImport(WechatOpenSDK)
        return WXApi.handleOpenUniversalLink(userActivity, delegate: self)
        #else
        return false
        #endif
    }

    /// 拉起微信授权，返回 code（交后端换 openid）。
    func authorize() async throws -> String {
        #if canImport(WechatOpenSDK)
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let req = SendAuthReq()
            req.scope = "snsapi_userinfo"
            req.state = "realtalk_login"
            WXApi.send(req)
        }
        #else
        throw NSError(domain: "WeChat", code: -1, userInfo: [NSLocalizedDescriptionKey: "未集成微信 SDK"])
        #endif
    }

    fileprivate func finish(code: String?, error: Error?) {
        guard let cont = continuation else { return }
        continuation = nil
        if let code, code.isEmpty == false {
            cont.resume(returning: code)
        } else {
            cont.resume(throwing: error ?? NSError(domain: "WeChat", code: -2, userInfo: [NSLocalizedDescriptionKey: "微信登录失败"]))
        }
    }
}

#if canImport(WechatOpenSDK)
import WechatOpenSDK

extension WeChatAuthManager: WXApiDelegate {
    nonisolated func onReq(_ req: BaseReq) {}

    nonisolated func onResp(_ resp: BaseResp) {
        guard let authResp = resp as? SendAuthResp else { return }
        let code = authResp.code
        let ok = authResp.errCode == 0
        Task { @MainActor in
            self.finish(code: ok ? code : nil,
                        error: ok ? nil : NSError(domain: "WeChat", code: Int(authResp.errCode),
                                                  userInfo: [NSLocalizedDescriptionKey: authResp.errStr ?? "微信登录失败"]))
        }
    }
}
#endif
