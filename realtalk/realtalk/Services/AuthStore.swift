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

    init(api: APIClient) {
        self.api = api
        token = UserDefaults.standard.string(forKey: tokenKey)
    }

    var isAuthenticated: Bool {
        token != nil
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
            let key = "RealTalk.devWeChatCode"
            let deviceSeed: String
            if let saved = UserDefaults.standard.string(forKey: key) {
                deviceSeed = saved
            } else {
                let created = "ios-dev-\(UUID().uuidString)"
                UserDefaults.standard.set(created, forKey: key)
                deviceSeed = created
            }
            return try await api.wechatLogin(code: deviceSeed, nickname: "微信用户", avatarUrl: nil)
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
