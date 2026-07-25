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
