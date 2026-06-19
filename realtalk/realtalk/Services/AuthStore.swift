import Combine
import Foundation

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var token: String?
    @Published private(set) var user: AppUser?
    @Published private(set) var isBusy = false
    @Published var statusMessage = ""

    private let api: APIClient
    private let tokenKey = "RealTalk.authToken"
    private let deviceKey = "RealTalk.deviceID"

    init(api: APIClient) {
        self.api = api
        token = UserDefaults.standard.string(forKey: tokenKey)
        // 账号被其它设备顶掉时，服务端返回 401 → 自动退出回到登录页
        api.onUnauthorized = { [weak self] in
            Task { @MainActor in self?.handleForcedLogout() }
        }
    }

    var isAuthenticated: Bool {
        token != nil
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
        token = nil
        user = nil
        UserDefaults.standard.removeObject(forKey: tokenKey)
        statusMessage = "账号已在其他设备登录，请重新授权登录"
    }

    func restoreSession() async {
        guard let token else { return }
        do {
            user = try await api.currentUser(token: token)
        } catch {
            logout()
            statusMessage = error.localizedDescription
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
        token = nil
        user = nil
        UserDefaults.standard.removeObject(forKey: tokenKey)
        statusMessage = "已退出登录"
    }

    private func authenticate(_ action: () async throws -> AuthResponse) async {
        isBusy = true
        defer { isBusy = false }

        do {
            let response = try await action()
            token = response.token
            user = response.user
            UserDefaults.standard.set(response.token, forKey: tokenKey)
            statusMessage = "登录成功"
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
