import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    // 直接观察 AuthStore：登录状态变化在 auth 上发布，必须订阅它才能切换界面
    @EnvironmentObject private var auth: AuthStore

    var body: some View {
        Group {
            if auth.isAuthenticated {
                MainChatView()
            } else {
                LoginView()
            }
        }
        .task {
            await model.bootstrap()
        }
    }
}
