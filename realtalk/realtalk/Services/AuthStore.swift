import Combine
import Foundation

@MainActor
final class AuthStore: ObservableObject {
    /// 会话状态。安全要点：本地有 token 不等于已登录，必须经服务端校验通过才放行主界面。
    enum SessionPhase {
        case checking      // 启动后正在向服务端校验本地 token
        case signedIn      // 服务端确认会话有效
        case signedOut     // 未登录 / 校验失败 / 已退出
    }

    @Published private(set) var token: String?
    @Published private(set) var user: AppUser?
    @Published private(set) var phase: SessionPhase
    @Published private(set) var isBusy = false
    @Published var statusMessage = ""

    private let api: APIClient
    private let tokenKey = "RealTalk.authToken"
    private let refreshKey = "RealTalk.refreshToken"
    private let deviceKey = "RealTalk.deviceID"
    private var refreshToken: String?
    private var refreshTask: Task<String?, Never>?

    init(api: APIClient) {
        self.api = api
        let saved = UserDefaults.standard.string(forKey: tokenKey)
        token = saved
        refreshToken = UserDefaults.standard.string(forKey: refreshKey)
        // 有本地 token：先进入「校验中」，必须等 /auth/me 通过才进主界面；没有 token 直接登录页
        phase = saved == nil ? .signedOut : .checking
        // 账号被其它设备顶掉/令牌被吊销时，服务端返回 401 → 自动退出回到登录页
        api.onUnauthorized = { [weak self] in
            self?.handleForcedLogout()
        }
        // access 过期时用 refresh 续期（单飞，避免并发请求重复刷新）
        api.onNeedsRefresh = { [weak self] in
            await self?.refreshAccessTokenIfPossible()
        }
    }

    /// 用 refresh 令牌换新的 access；并发调用合并为一次刷新。续期失败返回 nil 并清登录态。
    private func refreshAccessTokenIfPossible() async -> String? {
        if let task = refreshTask { return await task.value }
        let task = Task { [weak self] () -> String? in
            guard let self else { return nil }
            defer { self.refreshTask = nil }
            guard let refresh = self.refreshToken else { return nil }
            do {
                let resp = try await self.api.refreshToken(refreshToken: refresh)
                self.applyTokens(access: resp.accessToken, refresh: resp.refreshToken)
                return resp.accessToken
            } catch {
                self.clearSession(message: "登录已过期，请重新登录")
                return nil
            }
        }
        refreshTask = task
        return await task.value
    }

    private func applyTokens(access: String, refresh: String?) {
        token = access
        UserDefaults.standard.set(access, forKey: tokenKey)
        if let refresh {
            refreshToken = refresh
            UserDefaults.standard.set(refresh, forKey: refreshKey)
        }
    }

    var isAuthenticated: Bool {
        phase == .signedIn
    }

    /// 本机唯一安全编号：用于单设备登录绑定，持久化在本地。
    var deviceID: String {
        if let saved = UserDefaults.standard.string(forKey: deviceKey) {
            return saved
        }
        let created = "ios-\(UUID().uuidString)"
        UserDefaults.standard.set(created, forKey: deviceKey)
        return created
    }

    private func handleForcedLogout() {
        guard token != nil else { return }
        clearSession(message: "账号已在其他设备登录，请重新授权登录")
    }

    /// 启动时校验本地会话：只有服务端确认 token 有效（用户仍存在、设备未被顶掉）才进主界面。
    /// 服务器换库 / 用户被删 / 密钥变更 → /auth/me 返回 401 → 清登录态回登录页。
    func restoreSession() async {
        guard let token else {
            phase = .signedOut
            return
        }
        do {
            user = try await api.currentUser(token: token)
            phase = .signedIn
        } catch APIClientError.unauthorized {
            // 服务端明确否决：登录态无效，强制重新授权
            clearSession(message: "登录已失效，请重新登录")
        } catch {
            // 网络等暂时性错误：不放行进入主界面（安全优先），回登录页可重试
            phase = .signedOut
            statusMessage = "无法连接服务器，请重新登录"
        }
    }

    func sendEmailCode(email: String) async -> String? {
        isBusy = true
        defer { isBusy = false }

        do {
            let response = try await api.sendEmailCode(email: email)
            statusMessage = "验证码已发送"
            return response.devCode
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    func register(email: String, password: String, code: String) async {
        await authenticate {
            try await api.register(email: email, password: password, code: code)
        }
    }

    func login(email: String, password: String) async {
        await authenticate {
            try await api.login(email: email, password: password)
        }
    }

    func loginWithWeChat() async {
        await authenticate {
            if WeChatAuthManager.shared.isAvailable {
                // 真实微信一键登录：拉起微信授权拿 code，交后端用移动应用凭据换 openid
                let code = try await WeChatAuthManager.shared.authorize()
                return try await api.wechatLogin(code: code, nickname: nil, avatarUrl: nil, deviceId: deviceID)
            }
            // 未集成 SDK 或未配置 AppID：开发模拟登录
            let key = "RealTalk.devWeChatCode"
            let deviceSeed: String
            if let saved = UserDefaults.standard.string(forKey: key) {
                deviceSeed = saved
            } else {
                let created = "ios-dev-\(UUID().uuidString)"
                UserDefaults.standard.set(created, forKey: key)
                deviceSeed = created
            }
            return try await api.wechatLogin(code: deviceSeed, nickname: "微信用户", avatarUrl: nil, deviceId: deviceID)
        }
    }

    func applyBillingUser(_ updatedUser: AppUser) {
        user = updatedUser
    }

    func logout() {
        if let token {
            // 尽力注销服务端会话（吊销令牌/解绑设备），失败不影响本地清理
            Task { await api.serverLogout(token: token) }
        }
        clearSession(message: "已退出登录")
    }

    /// 统一清理登录态并回到登录页（清掉本地 access + refresh，避免下次启动又用旧 token 进主界面）。
    private func clearSession(message: String) {
        refreshTask?.cancel()
        refreshTask = nil
        token = nil
        refreshToken = nil
        user = nil
        phase = .signedOut
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: refreshKey)
        statusMessage = message
    }

    private func authenticate(_ action: () async throws -> AuthResponse) async {
        isBusy = true
        defer { isBusy = false }

        do {
            let response = try await action()
            applyTokens(access: response.token, refresh: response.refreshToken)
            user = response.user
            phase = .signedIn
            statusMessage = "登录成功"
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
