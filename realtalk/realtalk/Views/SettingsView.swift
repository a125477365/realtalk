import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var voiceCacheSize = VoiceCacheStore.shared.totalBytesText
    @State private var storageMessage = ""
    @State private var clearingChat = false
    @State private var confirmClearChat = false

    var body: some View {
        NavigationStack {
            Form {
                // 对话方式/指导方式/中文提示 等选择已全部移入对话界面内的小按钮（新交互）——设置页不再重复
                Section("外观") {
                    Picker("外观主题", selection: $model.appearance) {
                        ForEach(AppModel.AppAppearance.allCases) { Text($0.title).tag($0) }
                    }
                }

                Section("对话与字幕") {
                    if model.ttsConfigured, model.ttsVoices.isEmpty == false {
                        Picker("AI 朗读音色", selection: $model.ttsCurrentVoice) {
                            ForEach(model.ttsVoices, id: \.self) { Text($0).tag($0) }
                        }
                        .onChange(of: model.ttsCurrentVoice) { _, newValue in
                            Task { await model.setTtsVoice(newValue) }
                        }
                    }
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

                Section("存储管理") {
                    HStack {
                        Text("语音缓存")
                        Spacer()
                        Text(voiceCacheSize).foregroundStyle(.secondary)
                    }
                    Button("清除语音缓存", role: .destructive) {
                        storageMessage = model.clearVoiceCache()
                        voiceCacheSize = VoiceCacheStore.shared.totalBytesText
                    }
                    Button(clearingChat ? "正在清除聊天记录…" : "清除聊天记录", role: .destructive) {
                        confirmClearChat = true
                    }
                    .disabled(clearingChat)
                    if storageMessage.isEmpty == false {
                        Text(storageMessage)
                            .font(.system(size: 12 * model.fontScale))
                            .foregroundStyle(.secondary)
                    }
                }
                .confirmationDialog("清除聊天记录？私教/自由对话的历史将从服务器删除，无法恢复。",
                                    isPresented: $confirmClearChat, titleVisibility: .visible) {
                    Button("清除聊天记录", role: .destructive) {
                        clearingChat = true
                        Task { @MainActor in
                            storageMessage = await model.clearChatHistory()
                            clearingChat = false
                        }
                    }
                    Button("取消", role: .cancel) {}
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

                Section {
                    Toggle("智能电话提醒", isOn: $model.practiceReminderEnabled)
                    if model.practiceReminderEnabled {
                        Picker("提醒方式", selection: $model.reminderMode) {
                            Text("智能通知").tag("smart")
                            Text("定时通知").tag("timed")
                        }
                        if model.reminderMode == "smart" {
                            ForEach($model.reminderWindows) { $window in
                                HStack {
                                    DatePicker("", selection: $window.start, displayedComponents: .hourAndMinute)
                                        .labelsHidden()
                                    Text("至").foregroundStyle(.secondary)
                                    DatePicker("", selection: $window.end, displayedComponents: .hourAndMinute)
                                        .labelsHidden()
                                    Spacer()
                                    Button(role: .destructive) {
                                        model.reminderWindows.removeAll { $0.id == window.id }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            Button {
                                let cal = Calendar.current
                                let start = cal.date(bySettingHour: 19, minute: 0, second: 0, of: Date()) ?? Date()
                                let end = cal.date(bySettingHour: 21, minute: 0, second: 0, of: Date()) ?? Date()
                                model.reminderWindows.append(AppModel.CaptureWindow(start: start, end: end))
                            } label: {
                                Label("添加提醒学习时段", systemImage: "plus.circle.fill")
                            }
                        } else {
                            ForEach(Array(model.reminderTimes.enumerated()), id: \.offset) { index, _ in
                                HStack {
                                    DatePicker("", selection: Binding(
                                        get: { model.reminderTimes[index] },
                                        set: { model.reminderTimes[index] = $0 }
                                    ), displayedComponents: .hourAndMinute)
                                        .labelsHidden()
                                    Spacer()
                                    Button(role: .destructive) {
                                        model.reminderTimes.remove(at: index)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            Button {
                                let t = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date()) ?? Date()
                                model.reminderTimes.append(t)
                            } label: {
                                Label("添加提醒时间点", systemImage: "plus.circle.fill")
                            }
                        }
                    }
                } header: {
                    Text("学习提醒")
                        .font(.system(size: 13 * model.fontScale))
                } footer: {
                    Text("当天有新的未练习场景时，私教会以来电形式邀请你练习。智能：App 每 10 分钟上报信号，后端综合运动/心率/环境音/记忆作息判断空闲后来电——不设时段则 24 小时综合判断（默认避开深夜 23:00-8:00）；设了时段则只在时段内提醒（时段优先，可含深夜）。定时：在设定时间点来电。对话/采集中不打扰；挂断或暂不练习后该场景不再来电。")
                        .font(.system(size: 12 * model.fontScale))
                }

                Section("关于") {
                    LabeledContent("版本", value: appVersion)
                }
            }
            .navigationTitle("设置")
            .task { await model.loadTtsVoices() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: model.autoCaptureEnabled) { _, _ in model.saveCaptureSchedule() }
            .onChange(of: model.captureWindows) { _, _ in model.saveCaptureSchedule() }
            .onChange(of: model.appearance) { _, _ in model.savePracticePreferences() }
            .onChange(of: model.fontScale) { _, _ in model.savePracticePreferences() }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
