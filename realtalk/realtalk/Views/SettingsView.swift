import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("对话方式", selection: $model.conversationPreference) {
                        ForEach(AppModel.ConversationPreference.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("AI 指导方式", selection: $model.guidancePreference) {
                        ForEach(AppModel.GuidancePreference.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("对话方式").font(.system(size: 13 * model.fontScale))
                } footer: {
                    Text("对话中不可切换。手工触发式：长按说话、左滑取消、右滑发送。")
                        .font(.system(size: 12 * model.fontScale))
                }

                // 高级会员专属：沉浸式对话时改用实时语音大模型直接对话
                if model.isPremium {
                    Section {
                        Toggle("使用语音大模型进行交流", isOn: $model.voiceLLMPreference)
                    } header: {
                        Text("实时语音大模型（高级会员）").font(.system(size: 13 * model.fontScale))
                    } footer: {
                        Text("开启后在「沉浸式对话」中与语音大模型直接对话，结束给出评分。手工触发式不支持。")
                            .font(.system(size: 12 * model.fontScale))
                    }
                }

                Section("外观") {
                    Picker("外观主题", selection: $model.appearance) {
                        ForEach(AppModel.AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                }

                Section("对话与字幕") {
                    Toggle("显示双语字幕", isOn: $model.showDialogueContent)
                    Toggle("自动朗读 AI 台词", isOn: $model.autoSpeakAI)
                    Toggle("连续语音对话", isOn: $model.continuousVoiceMode)
                    Slider(value: $model.fontScale, in: 0.85...1.35, step: 0.05) {
                        Text("字体大小")
                    } minimumValueLabel: {
                        Text("小")
                    } maximumValueLabel: {
                        Text("大")
                    }
                    Text("当前字体 \(Int(model.fontScale * 100))%")
                        .font(.system(size: 12 * model.fontScale))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("按时间窗自动采集", isOn: $model.autoCaptureEnabled)
                    if model.autoCaptureEnabled {
                        ForEach($model.captureWindows) { $window in
                            HStack {
                                DatePicker("", selection: $window.start, displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                                Text("至").foregroundStyle(.secondary)
                                DatePicker("", selection: $window.end, displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                                Spacer()
                                Button(role: .destructive) {
                                    model.removeCaptureWindow(window.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button {
                            model.addCaptureWindow()
                        } label: {
                            Label("添加时段", systemImage: "plus.circle.fill")
                        }
                    }
                } header: {
                    Text("真实对话采集")
                        .font(.system(size: 13 * model.fontScale))
                } footer: {
                    Text("可添加多个时段，App 前台运行时会在任一时段内自动采集并转写。请在征得在场人员同意后使用。")
                        .font(.system(size: 12 * model.fontScale))
                }

                Section("关于") {
                    LabeledContent("版本", value: appVersion)
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: model.autoCaptureEnabled) { _, _ in model.saveCaptureSchedule() }
            .onChange(of: model.captureWindows) { _, _ in model.saveCaptureSchedule() }
            .onChange(of: model.appearance) { _, _ in model.savePracticePreferences() }
            .onChange(of: model.fontScale) { _, _ in model.savePracticePreferences() }
            .onChange(of: model.guidancePreference) { _, _ in model.savePracticePreferences() }
            .onChange(of: model.conversationPreference) { _, _ in model.savePracticePreferences() }
            .onChange(of: model.voiceLLMPreference) { _, _ in model.savePracticePreferences() }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
