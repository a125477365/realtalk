import Foundation

enum AppConfig {
    static let apiBaseURL: URL = {
        #if DEBUG
        // UI 自动化验证钩子（仅 Debug）：simctl launch 传 --uiverify-api <url> 指向本机联调后端
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--uiverify-api"), i + 1 < args.count, let u = URL(string: args[i + 1]) {
            return u
        }
        #endif
        return URL(string: "http://192.168.6.3:8000")!
    }()
    static let subscriptionProductID = "realtalk.pro.monthly"
    static let localRetentionDays = 3

    // 微信「移动应用」一键登录配置（在 open.weixin.qq.com 申请、审核通过后填写）。
    // 留空则 App 走开发模拟登录。Universal Link 需与开放平台后台填写的一致。
    static let wechatAppID = ""
    static let wechatUniversalLink = "https://realtalk.app/app/"
}
