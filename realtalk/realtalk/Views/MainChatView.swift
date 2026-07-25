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

/// 「严格/自由」二选一弹窗载荷（选场景后的第一问）。
private struct ModeChoice: Identifiable {
    let id = UUID()
    let summary: ScenarioSummary
}

/// 主界面（场景选择）：今天/全部/通用场景 → 点卡片 → 「手动触发 / 沉浸式」（两者都严格按剧本）
/// → 选角色（含续练判断）→ 全屏进入场景练习。右上角「A中」进入实时翻译。
/// asHome=true 时作为 App 根界面（顶栏显示账户与 A中，不显示关闭按钮）。
struct ScenarioPickerView: View {
    var asHome = false

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    @State private var modeChoice: ModeChoice?
    @State private var roleDialogScenario: ScenarioSummary?
    /// 选完角色后、若该场景有未完成进度，弹「继续 / 重新开始」二选一。
    @State private var resumeChoice: ResumeChoice?
    /// 选角色前记住本次选的是「沉浸式」还是「手动触发」。
    @State private var pendingImmersive = false
    @State private var showingAccount = false
    @State private var scenarioScope = "today"
    @State private var expandedPresetGroupID: String?
    @State private var expandedDate: Date?
    @State private var deleteCandidate: ScenarioSummary?

    var body: some View {
        NavigationStack {
            ZStack {
                RTTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    scenarioScopePicker
                    scenarioStrip
                }
            }
            .task {
                await model.loadScenarioList()
                await model.loadPracticeHistory()
                if asHome {
                    // 登录后补传：上次翻译没来得及上送的内容，这次继续送后台生成场景
                    await model.flushPendingTranslations()
                }
            }
            .modifier(ScenarioHomeCovers(asHome: asHome, showingAccount: $showingAccount))
            // 选场景 → 第一问：严格按剧本 / 围绕场景自由发挥（两种都全程纠错指导）
            .confirmationDialog(
                modeChoice.map { "「\($0.summary.title)」怎么练？" } ?? "选择方式",
                isPresented: Binding(
                    get: { modeChoice != nil },
                    set: { if $0 == false { modeChoice = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let choice = modeChoice {
                    // 两种都严格按剧本，区别只在说话方式
                    Button("手动触发（点击说话，逐句练）") {
                        modeChoice = nil
                        pendingImmersive = false
                        roleDialogScenario = choice.summary
                    }
                    Button("沉浸式（麦克风常开，连着说）") {
                        modeChoice = nil
                        pendingImmersive = true
                        roleDialogScenario = choice.summary
                    }
                    Button("取消", role: .cancel) { modeChoice = nil }
                }
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
                                let immersive = pendingImmersive
                                Task { await model.startStrictScene(summary, roleId: role.id, immersive: immersive) }
                                if asHome == false { dismiss() }
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
                        let immersive = pendingImmersive
                        Task { await model.startStrictScene(choice.summary, roleId: choice.roleId, resume: true, immersive: immersive) }
                        if asHome == false { dismiss() }
                    }
                    Button("从头重新开始") {
                        resumeChoice = nil
                        let immersive = pendingImmersive
                        Task { await model.startStrictScene(choice.summary, roleId: choice.roleId, resume: false, immersive: immersive) }
                        if asHome == false { dismiss() }
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

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("选择场景")
                    .font(.headline)
                    .foregroundStyle(RTTheme.textPrimary)
                Text("选一个场景，按真实对话逐句练")
                    .font(.system(size: 11 * model.fontScale))
                    .foregroundStyle(RTTheme.textSecondary)
            }
            Spacer()
            if asHome {
                // 右上角「A中」：进入实时翻译（翻译过程的真实对话会自动生成英文场景回到这个列表）
                Button { model.enterTranslate() } label: {
                    HStack(spacing: 3) {
                        Text("A").font(.system(size: 15 * model.fontScale, weight: .bold))
                        Image(systemName: "arrow.left.arrow.right").font(.system(size: 11, weight: .semibold))
                        Text("中").font(.system(size: 15 * model.fontScale, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RTTheme.accent, in: Capsule())
                }
                .accessibilityLabel("实时翻译")
                Button { showingAccount = true } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(RTTheme.textSecondary)
                }
                .accessibilityLabel("我的")
            } else {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(RTTheme.textSecondary)
                        .padding(9)
                        .background(RTTheme.hairline, in: Circle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                            modeChoice = ModeChoice(summary: model.summary(for: scene))
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
            modeChoice = ModeChoice(summary: summary)
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
                modeChoice = ModeChoice(summary: summary)
            } label: { Label("开始对话", systemImage: "bubble.left.and.bubble.right") }
            Button(role: .destructive) {
                deleteCandidate = summary
            } label: { Label("删除场景", systemImage: "trash") }
        }
    }
}

/// 主界面（asHome）挂的全屏页：实时翻译 / 场景练习 / 账户。抽成 modifier 保持列表视图本身简洁。
private struct ScenarioHomeCovers: ViewModifier {
    let asHome: Bool
    @Binding var showingAccount: Bool
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        if asHome {
            content
                .fullScreenCover(isPresented: $model.showTranslate) {
                    TranslateCallView(stream: model.freeStream)
                }
                .fullScreenCover(isPresented: $model.showScenePractice) {
                    ScenePracticeView(rpStream: model.stream)
                }
                .sheet(isPresented: $showingAccount) {
                    AccountPanelView().presentationDetents([.large])
                }
                .alert(item: $model.failureAlert) { alert in
                    Alert(title: Text(alert.title), message: Text(alert.message),
                          dismissButton: .default(Text("我知道了")))
                }
                .alert(item: $model.infoAlert) { alert in
                    Alert(title: Text(alert.title), message: Text(alert.message),
                          dismissButton: .default(Text("好的")))
                }
        } else {
            content
        }
    }
}

/// 「对话前询问」：指导/对话方式设为每次询问时，开练前选择本次方式（可勾选以后不再询问）。
