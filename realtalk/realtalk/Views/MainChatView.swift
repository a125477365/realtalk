import SwiftUI
import UIKit

/// 「继续 / 重新开始」二选一弹窗的载荷。
private struct ResumeChoice: Identifiable {
    let id = UUID()
    let summary: ScenarioSummary
    let roleId: String
}

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
    /// 选完角色后、若该场景有未完成进度，弹「继续 / 重新开始」二选一。
    @State private var resumeChoice: ResumeChoice?
    @State private var showImmersive = false
    @State private var scenarioScope = "today"
    @State private var expandedPresetGroupID: String?
    @State private var expandedDate: Date?
    @State private var deleteCandidate: ScenarioSummary?

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
            // 中断流程的系统/模型/额度异常：弹失败提示框
            .alert(item: $model.failureAlert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("我知道了")))
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
            .fullScreenCover(isPresented: $model.showFreeTalk) {
                FreeTalkView()
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
                await model.loadScenarioList()
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
                            if summary.inProgress {
                                // 有未完成进度：先问继续还是重新开始
                                resumeChoice = ResumeChoice(summary: summary, roleId: role.id)
                            } else {
                                Task { await model.startScenarioPractice(summary, roleId: role.id) }
                            }
                        }
                    }
                    Button("取消", role: .cancel) { roleDialogScenario = nil }
                }
            }
            .confirmationDialog(
                resumeChoice.map { "「\($0.summary.title)」有未完成的练习" } ?? "继续练习",
                isPresented: Binding(
                    get: { resumeChoice != nil },
                    set: { if $0 == false { resumeChoice = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let choice = resumeChoice {
                    Button("继续上次进度") {
                        resumeChoice = nil
                        Task { await model.startScenarioPractice(choice.summary, roleId: choice.roleId, resume: true) }
                    }
                    Button("从头重新开始") {
                        resumeChoice = nil
                        Task { await model.startScenarioPractice(choice.summary, roleId: choice.roleId, resume: false) }
                    }
                    Button("取消", role: .cancel) { resumeChoice = nil }
                }
            }
            .confirmationDialog(
                deleteCandidate.map { "删除场景「\($0.title)」？删除后将无法恢复。" } ?? "删除场景",
                isPresented: Binding(
                    get: { deleteCandidate != nil },
                    set: { if $0 == false { deleteCandidate = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let summary = deleteCandidate {
                    Button("删除", role: .destructive) {
                        deleteCandidate = nil
                        Task { await model.deleteScenario(summary.sceneId) }
                    }
                    Button("取消", role: .cancel) { deleteCandidate = nil }
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

            // 主界面最右侧：自由对话（一对一语音老师，无场景无指导，只有字幕）
            Button {
                model.startFreeTalk()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("自由对话")
                        .font(.system(size: 13 * model.fontScale, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RTTheme.brandGradient, in: Capsule())
            }
            .buttonStyle(.plain)
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
            options: [("today", "今天"), ("all", "全部"), ("preset", "通用场景")],
            fontScale: model.fontScale
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .onChange(of: scenarioScope) { _, scope in
            Task {
                if scope == "preset" {
                    await model.loadPresetCatalog()
                } else {
                    // 今天/全部都用同一份列表（按本地日期解读），避免「全部有今天的场景、今天标签却没有」的不一致
                    await model.loadScenarioList()
                }
            }
        }
    }

    // MARK: 今日场景

    private var scenarioStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(scopeHeaderTitle)
                    .font(.system(size: 12 * model.fontScale, weight: .semibold))
                    .foregroundStyle(RTTheme.textSecondary)
                Spacer()
                Button {
                    Task {
                        if scenarioScope == "preset" { await model.loadPresetCatalog() }
                        else { await model.loadScenarioList() }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(RTTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(model.isLoadingScenarios)
            }
            .padding(.horizontal, 16)

            if scenarioScope == "preset" {
                presetCatalogView
            } else if (scenarioScope == "all" ? model.todayScenarios.isEmpty : todayScenarioItems.isEmpty) {
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
            } else if scenarioScope == "all" {
                // 全部：先按日期折叠展示，点某天才展开当天的场景（与通用场景「主→子」一致）
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Text(historyWindowHint)
                            .font(.system(size: 12 * model.fontScale))
                            .foregroundStyle(RTTheme.textSecondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 2)
                        ForEach(allDateGroups, id: \.day) { group in
                            dateGroupCard(group)
                        }
                    }
                    .padding(.top, 4)
                }
            } else {
                // 今天：从同一份列表里按本地日期筛出今天的场景，平铺展示
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(todayScenarioItems) { scenarioCard($0) }
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

    /// 全部场景：按自然日分组（日期降序，组内时间降序），含今天。
    private var allDateGroups: [(day: Date, items: [ScenarioSummary])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: model.todayScenarios) { cal.startOfDay(for: $0.createdAt) }
        return groups
            .map { (day: $0.key, items: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { $0.day > $1.day }
    }

    /// 不同会员可见历史窗口的说明。
    private var historyWindowHint: String {
        switch auth.user?.effectiveTier {
        case "premium": return "高级会员可查看近 1 个月的历史场景"
        case "basic": return "基础会员可查看近 2 周的历史场景；升级高级会员可看近 1 个月"
        default: return "非会员仅显示近 2 天的场景；开通会员可保存更久（基础 2 周 / 高级 1 个月）"
        }
    }

    @ViewBuilder
    private func dateGroupCard(_ group: (day: Date, items: [ScenarioSummary])) -> some View {
        let isExpanded = expandedDate == group.day
        let isToday = Calendar.current.isDateInToday(group.day)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedDate = isExpanded ? nil : group.day
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
                        .foregroundStyle(RTTheme.accent)
                    Text(isToday ? "今天" : group.day.formatted(.dateTime.year().month().day()))
                        .font(.system(size: 16 * model.fontScale, weight: .semibold))
                        .foregroundStyle(RTTheme.textPrimary)
                    Spacer()
                    Text("\(group.items.count) 个")
                        .font(.system(size: 11 * model.fontScale))
                        .foregroundStyle(RTTheme.textSecondary.opacity(0.8))
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(RTTheme.textSecondary.opacity(0.6))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 10) {
                    ForEach(group.items) { scenarioCard($0) }
                }
                .padding(.bottom, 10)
            }
        }
        .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RTTheme.hairline))
        .padding(.horizontal, 16)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13 * model.fontScale, weight: .semibold))
            .foregroundStyle(RTTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
    }

    private var scopeHeaderTitle: String {
        switch scenarioScope {
        case "preset": return "通用场景"
        case "all": return "全部场景"
        default: return "今日场景"
        }
    }

    // MARK: 通用场景（运维预置的全局场景，已含完整对话；主场景 → 子场景两级选择，点开即对练）

    @ViewBuilder
    private var presetCatalogView: some View {
        if model.presetCatalog.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.stack.badge.person.crop")
                    .font(.title2)
                    .foregroundStyle(RTTheme.textSecondary)
                Text("暂无通用场景")
                    .font(.system(size: 14 * model.fontScale, weight: .medium))
                    .foregroundStyle(RTTheme.textPrimary)
                Text("没有录音也能练：选一个场景，直接与 AI 对话")
                    .font(.system(size: 12 * model.fontScale))
                    .foregroundStyle(RTTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
            .padding(.horizontal, 24)
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text("没有录音也能练：选一个场景，直接进入对话练习")
                        .font(.system(size: 12 * model.fontScale))
                        .foregroundStyle(RTTheme.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                    ForEach(model.presetCatalog) { group in
                        presetGroupCard(group)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func presetGroupCard(_ group: PresetSceneGroup) -> some View {
        let isExpanded = expandedPresetGroupID == group.id
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedPresetGroupID = isExpanded ? nil : group.id
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2")
                        .foregroundStyle(RTTheme.accent)
                    Text(group.group)
                        .font(.system(size: 16 * model.fontScale, weight: .semibold))
                        .foregroundStyle(RTTheme.textPrimary)
                    Spacer()
                    Text("\(group.scenes.count) 个")
                        .font(.system(size: 11 * model.fontScale))
                        .foregroundStyle(RTTheme.textSecondary.opacity(0.8))
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(RTTheme.textSecondary.opacity(0.6))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.scenes) { scene in
                        Divider().background(RTTheme.hairline).padding(.leading, 14)
                        Button {
                            roleDialogScenario = model.summary(for: scene)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "play.circle")
                                    .foregroundStyle(RTTheme.textSecondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(scene.title)
                                        .font(.system(size: 14 * model.fontScale))
                                        .foregroundStyle(RTTheme.textPrimary)
                                    Text("\(scene.lineCount) 句")
                                        .font(.system(size: 11 * model.fontScale))
                                        .foregroundStyle(RTTheme.textSecondary.opacity(0.8))
                                }
                                Spacer()
                                lastScoreBadge(scene.lastScore)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(RTTheme.textSecondary.opacity(0.6))
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isBusy)
                    }
                }
            }
        }
        .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RTTheme.hairline))
        .padding(.horizontal, 16)
    }

    /// 上一次对练得分小标签（场景卡用）。
    @ViewBuilder
    private func lastScoreBadge(_ score: Int?) -> some View {
        if let score {
            Text("上次 \(score)")
                .font(.system(size: 11 * model.fontScale, weight: .semibold))
                .foregroundStyle(score >= 80 ? RTTheme.success : RTTheme.accent)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background((score >= 80 ? RTTheme.success : RTTheme.accent).opacity(0.12), in: Capsule())
        }
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
                lastScoreBadge(summary.lastScore)
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
        .disabled(model.isBusy)
        // 长按弹「开始对话 / 删除场景」；单击仍是直接进入对练（不变）
        .contextMenu {
            Button {
                roleDialogScenario = summary
            } label: { Label("开始对话", systemImage: "bubble.left.and.bubble.right") }
            Button(role: .destructive) {
                deleteCandidate = summary
            } label: { Label("删除场景", systemImage: "trash") }
        }
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
        // 等待后台处理（含通用场景生成）时禁用，避免误触发新请求；采集中仍可点击以停止
        .disabled(model.isBusy)
        .opacity(model.isBusy ? 0.55 : 1)
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
    @State private var conversation: AppModel.ConversationMode = .manual   // 默认手工触发式
    @State private var guidance: AppModel.GuidanceMode = .realtime
    @State private var rememberConversation = false
    @State private var rememberGuidance = false

    var body: some View {
        NavigationStack {
            Form {
                if model.conversationPreference == .ask {
                    Section("对话方式") {
                        Picker("对话方式", selection: $conversation) {
                            if model.isPremium {
                                Text("语音模型对话").tag(AppModel.ConversationMode.voice)
                            }
                            Text("沉浸式对话").tag(AppModel.ConversationMode.immersive)
                            Text("手工触发式对话").tag(AppModel.ConversationMode.manual)
                        }
                        .pickerStyle(.segmented)
                        if conversation == .voice {
                            Text("与实时语音大模型直接语音对话，结束后给出评分。")
                                .font(.system(size: 12 * model.fontScale))
                                .foregroundStyle(.secondary)
                        }
                        Toggle("以后不再询问，按此设置", isOn: $rememberConversation)
                    }
                }
                // 语音模型对话不走逐句文字指导，故选它时不再询问指导方式
                if model.guidancePreference == .ask && conversation != .voice {
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
                            : model.resolvedConversationMode(model.conversationPreference)
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
