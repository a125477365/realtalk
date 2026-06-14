import SwiftUI

/// Claude 风格的对话主界面：奶白底色、助手消息纯文本、用户消息浅色气泡、
/// 系统提示居中胶囊；字幕随对话自动向上滚动。
enum RTTheme {
    static let background = Color(red: 0.965, green: 0.957, blue: 0.937)   // 奶白
    static let surface = Color.white
    static let userBubble = Color(red: 0.922, green: 0.910, blue: 0.878)
    static let accent = Color(red: 0.78, green: 0.42, blue: 0.26)          // 暖陶土色
    static let textPrimary = Color(red: 0.13, green: 0.12, blue: 0.11)
    static let textSecondary = Color(red: 0.45, green: 0.43, blue: 0.40)
    static let hairline = Color.black.opacity(0.08)
}

struct MainChatView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var speech: SpeechCaptureManager
    @EnvironmentObject private var practiceSpeech: SpeechPracticeManager
    @EnvironmentObject private var voice: VoicePromptPlayer

    @State private var draft = ""
    @State private var showingAccount = false
    @State private var roleDialogScenario: ScenarioSummary?

    var body: some View {
        NavigationStack {
            ZStack {
                RTTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    scenarioStrip
                    messages
                    composer
                }
            }
            .task {
                // 登录后进入主界面时加载数据（bootstrap 在登录前已跑过、那时无 token 被跳过）
                await model.loadBillingAccount()
                await model.loadTodayScenarios()
                await model.loadPracticeHistory()
            }
            .sheet(isPresented: $showingAccount) {
                AccountPanelView()
                    .presentationDetents([.large])
            }
            .confirmationDialog(
                roleDialogScenario.map { "练习「\($0.title)」，你想扮演谁？" } ?? "选择角色",
                isPresented: Binding(
                    get: { roleDialogScenario != nil },
                    set: { if $0 == false { roleDialogScenario = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let summary = roleDialogScenario {
                    ForEach(summary.roles.filter(\.isUserCandidate)) { role in
                        Button("\(role.name)（\(role.description)）") {
                            roleDialogScenario = nil
                            Task { await model.startScenarioPractice(summary, roleId: role.id) }
                        }
                    }
                    Button("取消", role: .cancel) { roleDialogScenario = nil }
                }
            }
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                showingAccount = true
            } label: {
                ZStack {
                    Circle().fill(RTTheme.accent.opacity(0.16))
                    Text((auth.user?.displayName ?? "我").prefix(1))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RTTheme.accent)
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text("RealTalk")
                    .font(.headline)
                    .foregroundStyle(RTTheme.textPrimary)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(RTTheme.textSecondary)
            }

            Spacer()

            Button {
                Task {
                    await model.sendMainChatMessage(speech.isRecording ? "停止录音" : "开始录音")
                }
            } label: {
                Image(systemName: speech.isRecording ? "record.circle.fill" : "waveform")
                    .font(.title3)
                    .foregroundStyle(speech.isRecording ? .red : RTTheme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(RTTheme.surface, in: Circle())
                    .overlay(Circle().stroke(RTTheme.hairline))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: 今日场景

    private var scenarioStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("今日场景")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(RTTheme.textSecondary)
                Spacer()
                Button {
                    Task { await model.loadTodayScenarios() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(RTTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(model.isLoadingScenarios)
            }
            .padding(.horizontal, 16)

            if model.todayScenarios.isEmpty {
                // 空态：引导用户先采集真实对话或上传录音（场景只能来自真实对话）
                Button {
                    Task { await model.sendMainChatMessage(speech.isRecording ? "停止录音" : "开始录音") }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform.badge.plus")
                            .foregroundStyle(RTTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.isLoadingScenarios ? "正在加载今日场景…" : "今天还没有场景")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(RTTheme.textPrimary)
                            Text("点这里采集今天的真实对话，自动生成练习场景")
                                .font(.caption)
                                .foregroundStyle(RTTheme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(RTTheme.hairline))
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.todayScenarios) { summary in
                            Button {
                                roleDialogScenario = summary
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(summary.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(RTTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(summary.summary)
                                        .font(.caption)
                                        .foregroundStyle(RTTheme.textSecondary)
                                        .lineLimit(2)
                                    Text("\(summary.lineCount) 句 · \(summary.createdAt.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption2)
                                        .foregroundStyle(RTTheme.textSecondary.opacity(0.8))
                                }
                                .padding(12)
                                .frame(width: 200, alignment: .leading)
                                .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(RTTheme.hairline))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: 消息流（字幕自动上滚）

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.chatMessages) { message in
                        ChatRow(message: message)
                            .id(message.id)
                    }
                    if practiceSpeech.partialText.isEmpty == false {
                        // 实时识别字幕：用户开口时同步显示
                        HStack {
                            Spacer(minLength: 56)
                            Text(practiceSpeech.partialText)
                                .font(.body)
                                .foregroundStyle(RTTheme.textSecondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(RTTheme.userBubble.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
                        }
                        .id("partial")
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.chatMessages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: practiceSpeech.partialText) { _, text in
                guard text.isEmpty == false else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    // MARK: 输入栏

    private var composer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("和 RealTalk 说说今天想练什么", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.body)
                    .textFieldStyle(.plain)
                    .padding(.leading, 16)

                Button {
                    Task { await model.toggleVoiceConversation() }
                } label: {
                    Image(systemName: model.isVoiceConversationActive ? "pause.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(model.isVoiceConversationActive ? .orange : RTTheme.accent)
                }
                .buttonStyle(.plain)
                .disabled(model.isWorking)

                Button {
                    Task { await sendDraft() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(
                            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? RTTheme.textSecondary.opacity(0.4)
                                : RTTheme.accent
                        )
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
            }
            .padding(.vertical, 7)
            .padding(.trailing, 8)
            .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(RTTheme.hairline))
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .background(RTTheme.background)
    }

    private var statusText: String {
        if voice.isSpeaking { return "AI 正在说话…" }
        if practiceSpeech.isListening { return "正在听你说英语…" }
        if speech.isRecording { return "正在采集真实对话…" }
        if let usage = model.billingAccount?.usage, usage.overLimit {
            return "今日 AI 用量已达上限"
        }
        return auth.user?.tierName ?? "用真实生活练英语"
    }

    private func sendDraft() async {
        let text = draft
        draft = ""
        await model.sendMainChatMessage(text)
    }
}

// MARK: - 消息行

struct ChatRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.sender {
        case .assistant:
            // Claude 风格：助手消息纯文本，无气泡
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(RTTheme.accent.opacity(0.9))
                    .frame(width: 6, height: 6)
                    .padding(.top, 8)
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(RTTheme.textPrimary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .user:
            HStack {
                Spacer(minLength: 56)
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(RTTheme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RTTheme.userBubble, in: RoundedRectangle(cornerRadius: 18))
            }
        case .system:
            // 「轮到你」等提示：居中胶囊
            HStack {
                Spacer()
                Text(message.text)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(RTTheme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RTTheme.accent.opacity(0.10), in: Capsule())
                Spacer()
            }
        }
    }
}
