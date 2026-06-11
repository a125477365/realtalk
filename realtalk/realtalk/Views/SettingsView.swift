import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("对话与字幕") {
                    Toggle("显示双语字幕", isOn: $model.showDialogueContent)
                    Toggle("自动朗读 AI 台词", isOn: $model.autoSpeakAI)
                    Toggle("连续语音对话", isOn: $model.continuousVoiceMode)
                }

                Section {
                    Toggle("按时间窗自动采集", isOn: $model.autoCaptureEnabled)
                    if model.autoCaptureEnabled {
                        DatePicker("开始时间", selection: $model.autoCaptureStart, displayedComponents: .hourAndMinute)
                        DatePicker("结束时间", selection: $model.autoCaptureEnd, displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("真实对话采集")
                } footer: {
                    Text("开启后，App 在前台运行时会在设定时间窗内自动采集并转写周围对话，采集期间状态栏会有明显提示。请在征得在场人员同意后使用。")
                }

                Section("账号") {
                    LabeledContent("登录方式", value: auth.user?.displayName ?? "微信用户")
                    LabeledContent("用户 ID", value: String((auth.user?.id ?? "—").prefix(8)) + "…")
                    LabeledContent("套餐", value: auth.user?.plan == "pro" ? "Pro" : "免费版")
                    Button("退出登录", role: .destructive) {
                        auth.logout()
                        dismiss()
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: appVersion)
                    LabeledContent("服务地址", value: AppConfig.apiBaseURL.absoluteString)
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: model.autoCaptureEnabled) { _, _ in model.saveCaptureSchedule() }
            .onChange(of: model.autoCaptureStart) { _, _ in model.saveCaptureSchedule() }
            .onChange(of: model.autoCaptureEnd) { _, _ in model.saveCaptureSchedule() }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
