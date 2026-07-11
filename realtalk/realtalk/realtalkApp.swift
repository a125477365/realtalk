//
//  realtalkApp.swift
//  realtalk
//
//  Created by 谭坚 on 2026/6/3.
//

import BackgroundTasks
import SwiftUI

@main
struct realtalkApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 学习提醒后台刷新（类似 IM 的后台能力，由系统调度、App 不常驻）：
        // 后台醒来 → 跑与前台相同的判定（App 触发 + 后端综合裁决）→ 判定来电则发本地通知，点通知进 App 弹「私教来电」。
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.realtalk.reminder.refresh", using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Self.scheduleReminderRefresh()   // 先排下一次，保证链式续约
            let work = Task { @MainActor in
                let fired = await AppModel.backgroundReminderCheck()
                refresh.setTaskCompleted(success: fired)
            }
            refresh.expirationHandler = { work.cancel() }
        }
    }

    static func scheduleReminderRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.realtalk.reminder.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60)   // 最早 10 分钟后（实际由系统按使用习惯调度）
        try? BGTaskScheduler.shared.submit(request)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(model.appearance.colorScheme)
                .environmentObject(model)
                .environmentObject(model.transcripts)
                .environmentObject(model.speech)
                .environmentObject(model.auth)
                .environmentObject(model.subscription)
                .environmentObject(model.practiceSpeech)
                .environmentObject(model.voice)
                .environmentObject(model.stream)
                .onAppear { WeChatAuthManager.shared.registerIfNeeded() }
                .onOpenURL { url in
                    _ = WeChatAuthManager.shared.handleOpen(url: url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    _ = WeChatAuthManager.shared.handleUniversalLink(activity)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task {
                            await model.handlePendingShortcutAction()
                            // 从通知点开/回到前台：立即补一次学习提醒判定（前台弹「私教来电」）
                            await model.checkPracticeReminder()
                            #if DEBUG
                            // UI 自动化验证钩子（仅 Debug 构建）：xcrun simctl launch 传参直开私教/翻译界面
                            let uiArgs = ProcessInfo.processInfo.arguments
                            if uiArgs.contains("--uiverify-login"), model.auth.token == nil {
                                await model.auth.loginWithWeChat()   // 开发模拟登录（未配微信 SDK 时）
                            }
                            if model.showTutor == false, model.auth.token != nil {
                                if uiArgs.contains("--uiverify-freetalk-translate") {
                                    model.tutorMode = "translate"
                                    model.showTutor = true
                                } else if uiArgs.contains("--uiverify-freetalk") {
                                    model.tutorMode = "chat"
                                    model.showTutor = true
                                } else if uiArgs.contains("--uiverify-scenepicker") {
                                    model.showScenePicker = true
                                }
                            }
                            #endif
                        }
                    case .background:
                        if model.practiceReminderEnabled { Self.scheduleReminderRefresh() }
                    default:
                        break
                    }
                }
        }
    }
}
