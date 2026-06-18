import AppIntents
import Foundation

enum RealTalkShortcutAction: String {
    case startCapture
    case stopCapture

    static let defaultsKey = "realtalk.pendingShortcutAction"
    static let notification = Notification.Name("RealTalkShortcutAction")

    func publish() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.notification, object: rawValue)
    }

    static func consumePending() -> RealTalkShortcutAction? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return RealTalkShortcutAction(rawValue: raw)
    }
}

struct StartRealTalkCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 RealTalk 进行录音"
    static let description = IntentDescription("开始采集真实中文日常对话。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        RealTalkShortcutAction.startCapture.publish()
        return .result(dialog: "RealTalk 已开始准备录音")
    }
}

struct StopRealTalkCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "结束 RealTalk 录音"
    static let description = IntentDescription("停止采集并上传对话生成英语场景。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        RealTalkShortcutAction.stopCapture.publish()
        return .result(dialog: "RealTalk 正在结束录音并生成场景")
    }
}

struct RealTalkAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRealTalkCaptureIntent(),
            phrases: [
                "请打开我的 \(.applicationName) 进行录音",
                "打开 \(.applicationName) 录音",
            ],
            shortTitle: "开始录音",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: StopRealTalkCaptureIntent(),
            phrases: [
                "请结束 \(.applicationName) 录音",
                "结束 \(.applicationName) 录音",
            ],
            shortTitle: "结束录音",
            systemImageName: "stop.circle"
        )
    }
}
