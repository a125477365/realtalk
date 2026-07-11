import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    // 直接观察 AuthStore：登录状态变化在 auth 上发布，必须订阅它才能切换界面
    @EnvironmentObject private var auth: AuthStore

    var body: some View {
        Group {
            switch auth.phase {
            case .checking:
                // 安全：本地有 token 也不直接进主界面，先向服务端校验会话有效性
                SessionCheckingView()
            case .signedIn:
                ChatHomeView(freeStream: model.freeStream, rpStream: model.stream)
            case .signedOut:
                LoginView()
            }
        }
        .task {
            await model.bootstrap()
            #if DEBUG
            // UI 自动化验证钩子（仅 Debug）：在 bootstrap 之后可靠触发（scenePhase.onChange 冷启动不稳）
            let uiArgs = ProcessInfo.processInfo.arguments
            if uiArgs.contains("--uiverify-login"), auth.phase != .signedIn {
                await model.auth.loginWithWeChat()
            }
            if model.showTutor == false, model.auth.token != nil {
                if uiArgs.contains("--uiverify-freetalk-translate") {
                    model.tutorMode = "translate"; model.showTutor = true
                } else if uiArgs.contains("--uiverify-freetalk") {
                    model.tutorMode = "chat"; model.showTutor = true
                } else if uiArgs.contains("--uiverify-scenepicker") {
                    model.showScenePicker = true
                }
            }
            #endif
        }
    }
}

/// 启动校验过渡页：避免「本地有 token 就先闪进主界面」这种不安全的体验。
private struct SessionCheckingView: View {
    var body: some View {
        ZStack {
            DreamyBackdrop()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("正在验证登录…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}
