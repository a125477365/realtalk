import SwiftUI
import UIKit

/// Claude 风格的对话主界面：内容区背景跟随外观主题（浅色/深色/系统），
/// 助手消息纯文本、用户消息浅色气泡、系统提示居中胶囊；字幕随对话自动向上滚动。
enum RTTheme {
    /// 随系统深浅自动切换的动态颜色。
    static func dynamic(light: Color, dark: Color) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    // 统一品牌：「梦幻」渐变作为 Hero/强调；内容区背景跟随系统深浅
    static let background = dynamic(light: Color(red: 0.969, green: 0.973, blue: 0.984),
                                    dark: Color(red: 0.07, green: 0.08, blue: 0.10))
    static let surface = dynamic(light: .white, dark: Color(red: 0.13, green: 0.14, blue: 0.17))
    static let userBubble = dynamic(light: Color(red: 0.918, green: 0.953, blue: 0.996),
                                    dark: Color(red: 0.16, green: 0.22, blue: 0.33))
    static let accent = Color(red: 0.16, green: 0.56, blue: 0.96)          // 天蓝 #2997F5（取自渐变起点）
    static let success = Color(red: 0.086, green: 0.639, blue: 0.290)      // 进步绿 #16A34A
    static let textPrimary = dynamic(light: Color(red: 0.086, green: 0.094, blue: 0.114),
                                     dark: Color(red: 0.93, green: 0.94, blue: 0.96))
    static let textSecondary = dynamic(light: Color(red: 0.357, green: 0.380, blue: 0.431),
                                       dark: Color(red: 0.62, green: 0.65, blue: 0.71))
    static let hairline = dynamic(light: Color.black.opacity(0.07), dark: Color.white.opacity(0.12))

    // 蓝→青→粉→橙 梦幻渐变
    static let brandColors = [
        Color(red: 0.16, green: 0.56, blue: 0.96),
        Color(red: 0.10, green: 0.78, blue: 0.70),
        Color(red: 0.96, green: 0.56, blue: 0.72),
        Color(red: 1.00, green: 0.78, blue: 0.42),
    ]
    static let brandGradient = LinearGradient(
        colors: brandColors,
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct MainChatView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var speech: SpeechCaptureManager
    @EnvironmentObject private var practiceSpeech: SpeechPracticeManager
    @EnvironmentObject private var voice: VoicePromptPlayer

    @State private var showingAccount = false
    @State private var roleDialogScenario: ScenarioSummary?
    @State private var showImmersive = false
    @State private var scenarioScope = "today"

    var body: some View {
        NavigationStack {
            ZStack {
                RTTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    statusPill
                    scenarioScopePicker
                    scenarioStrip
                    captureButton
                }
            }
            // 开始对练即进入沉浸式字幕；练习完成或退出回到聊天
            .onChange(of: model.roleplay?.sessionId) { _, sid in
                if sid != nil, model.roleplay?.completed == false { showImmersive = true }
            }
            .fullScreenCover(isPresented: $showImmersive) {
                ImmersiveRoleplayView()
            }
            // 高级会员沉浸式 + 实时语音大模型对练
            .fullScreenCover(isPresented: $model.showVoiceLLM) {
                ImmersiveVoiceLLMView()
            }
            .sheet(isPresented: Binding(
                get: { model.pendingPractice != nil },
                set: { if $0 == false { model.cancelPendingPractice() } }
            )) {
                PrePracticeSheet()
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
                    Circle().fill(RTTheme.brandGradient)
                    Text((auth.user?.displayName ?? "我").prefix(1))
                        .font(.system(size: 15 * model.fontScale, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text("RealTalk")
                    .font(.headline)
                    .foregroundStyle(RTTheme.textPrimary)
                Text("场景列表与日期选择")
                    .font(.system(size: 11 * model.fontScale))
                    .foregroundStyle(RTTheme.textSecondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // 顶部状态：低调的「圆点 + 文字」指示器，不再是抢眼的彩色胶囊
    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(model.statusMessage.isEmpty ? statusText : model.statusMessage)
                .font(.system(size: 12 * model.fontScale, weight: .medium))
                .foregroundStyle(RTTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 10)
    }

    private var scenarioScopePicker: some View {
        BrandSegmentedPicker(
            selection: $scenarioScope,
            options: [("today", "今天"), ("all", "全部")],
            fontScale: model.fontScale
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .onChange(of: scenarioScope) { _, scope in
            Task {
                if scope == "all" {
                    await model.loadScenarioList()
                } else {
                    await model.loadTodayScenarios()
                }
            }
        }
    }

    // MARK: 今日场景

    private var scenarioStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(scenarioScope == "today" ? "今日场景" : "全部场景")
                    .font(.system(size: 12 * model.fontScale, weight: .semibold))
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
                    Task { await model.toggleRecording() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform.badge.plus")
                            .foregroundStyle(RTTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.isLoadingScenarios ? "正在加载今日场景…" : "今天还没有场景")
                                .font(.system(size: 15 * model.fontScale, weight: .semibold))
                                .foregroundStyle(RTTheme.textPrimary)
                            Text("点底部按钮采集今天的真实对话，停止后自动生成英语场景")
                                .font(.system(size: 12 * model.fontScale))
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
                // 竖排列表；「全部」按日期分组展示
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if scenarioScope == "all" {
                            let today = todayScenarioItems
                            let history = historyGroups
                            if today.isEmpty == false {
                                sectionHeader("今天")
                                ForEach(today) { scenarioCard($0) }
                            }
                            if history.isEmpty == false {
                                sectionHeader("历史")
                                ForEach(history, id: \.day) { group in
                                    Text(group.day.formatted(.dateTime.year().month().day()))
                                        .font(.system(size: 11 * model.fontScale, weight: .medium))
                                        .foregroundStyle(RTTheme.textSecondary.opacity(0.8))
                                        .padding(.horizontal, 20)
                                        .padding(.top, 2)
                                    ForEach(group.items) { scenarioCard($0) }
                                }
                            }
                        } else {
                            ForEach(model.todayScenarios) { scenarioCard($0) }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.bottom, 8)
    }

    /// 今天的场景（时间降序）。
    private var todayScenarioItems: [ScenarioSummary] {
        let cal = Calendar.current
        return model.todayScenarios
            .filter { cal.isDateInToday($0.createdAt) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 历史场景：非今天，按自然日分组（日期降序，组内时间降序）。
    private var historyGroups: [(day: Date, items: [ScenarioSummary])] {
        let cal = Calendar.current
        let past = model.todayScenarios.filter { cal.isDateInToday($0.createdAt) == false }
        let groups = Dictionary(grouping: past) { cal.startOfDay(for: $0.createdAt) }
        return groups
            .map { (day: $0.key, items: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { $0.day > $1.day }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13 * model.fontScale, weight: .semibold))
            .foregroundStyle(RTTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
    }

    @ViewBuilder
    private func scenarioCard(_ summary: ScenarioSummary) -> some View {
        Button {
            roleDialogScenario = summary
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.title)
                        .font(.system(size: 16 * model.fontScale, weight: .semibold))
                        .foregroundStyle(RTTheme.textPrimary)
                        .lineLimit(1)
                    Text(summary.summary)
                        .font(.system(size: 13 * model.fontScale))
                        .foregroundStyle(RTTheme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(summary.lineCount) 句 · \(summary.createdAt.formatted(date: scenarioScope == "all" ? .abbreviated : .omitted, time: .shortened))")
                        .font(.system(size: 11 * model.fontScale))
                        .foregroundStyle(RTTheme.textSecondary.opacity(0.8))
                }
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(RTTheme.textSecondary.opacity(0.6))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(RTTheme.hairline))
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    private var captureButton: some View {
        Button {
            Task { await model.toggleRecording() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: speech.isRecording ? "stop.fill" : "waveform.badge.plus")
                    .font(.system(size: 20, weight: .semibold))
                Text(speech.isRecording ? "停止采集并生成场景" : "开始采集日常对话")
                    .font(.system(size: 16 * model.fontScale, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(speech.isRecording ? AnyShapeStyle(Color.red) : AnyShapeStyle(RTTheme.brandGradient), in: Capsule())
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .buttonStyle(.plain)
        .disabled(model.isWorking)
        .background(RTTheme.background)
    }

    private var statusText: String {
        if voice.isSpeaking { return "AI 正在说话…" }
        if practiceSpeech.isListening { return "正在听你说英语…" }
        if speech.isRecording { return "正在采集真实对话…" }
        if model.isWorking { return "正在处理，请稍等" }
        if let usage = model.billingAccount?.usage, usage.overBudget {
            return "本月 AI 额度已用完"
        }
        return auth.user?.tierName ?? "用真实生活练英语"
    }

    private var statusColor: Color {
        if speech.isRecording { return .red }
        if voice.isSpeaking { return .orange }
        if practiceSpeech.isListening { return RTTheme.success }
        if model.isWorking { return RTTheme.accent }
        return RTTheme.textSecondary
    }

}

/// 「对话前询问」：指导/对话方式设为每次询问时，开练前选择本次方式（可勾选以后不再询问）。
private struct PrePracticeSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var conversation: AppModel.ConversationMode = .immersive
    @State private var guidance: AppModel.GuidanceMode = .realtime
    @State private var rememberConversation = false
    @State private var rememberGuidance = false

    var body: some View {
        NavigationStack {
            Form {
                if model.conversationPreference == .ask {
                    Section("对话方式") {
                        Picker("对话方式", selection: $conversation) {
                            Text("沉浸式对话").tag(AppModel.ConversationMode.immersive)
                            Text("手工触发式对话").tag(AppModel.ConversationMode.manual)
                        }
                        .pickerStyle(.segmented)
                        Toggle("以后不再询问，按此设置", isOn: $rememberConversation)
                    }
                }
                if model.guidancePreference == .ask {
                    Section("指导方式") {
                        Picker("指导方式", selection: $guidance) {
                            Text("实时指导").tag(AppModel.GuidanceMode.realtime)
                            Text("结束后指导").tag(AppModel.GuidanceMode.final)
                        }
                        .pickerStyle(.segmented)
                        Toggle("以后不再询问，按此设置", isOn: $rememberGuidance)
                    }
                }
            }
            .navigationTitle("开始练习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { model.cancelPendingPractice() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("开始") {
                        let conv: AppModel.ConversationMode = model.conversationPreference == .ask
                            ? conversation
                            : (model.conversationPreference == .manual ? .manual : .immersive)
                        let guid: AppModel.GuidanceMode = model.guidancePreference == .ask
                            ? guidance
                            : (model.guidancePreference == .final ? .final : .realtime)
                        Task {
                            await model.confirmPendingPractice(
                                conversation: conv,
                                guidance: guid,
                                rememberConversation: rememberConversation,
                                rememberGuidance: rememberGuidance
                            )
                        }
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
