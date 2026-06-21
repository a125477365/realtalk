import AVFoundation
import Combine
import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum GuidanceMode: String, CaseIterable, Identifiable {
        case realtime
        case final

        var id: String { rawValue }
        var title: String {
            switch self {
            case .realtime: return "实时指导"
            case .final: return "结束后指导"
            }
        }
    }

    /// 指导方式偏好：可选「每次开始对话前询问」。对话中不可切换。
    enum GuidancePreference: String, CaseIterable, Identifiable {
        case ask
        case realtime
        case final

        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: return "每次开始对话前询问"
            case .realtime: return "实时指导"
            case .final: return "结束后指导"
            }
        }
    }

    /// 对话方式（当前会话生效，不可中途切换）。
    enum ConversationMode: String { case immersive, manual }

    /// 对话方式偏好：可选「每次开始对话前询问」。
    enum ConversationPreference: String, CaseIterable, Identifiable {
        case ask
        case immersive
        case manual

        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: return "每次开始对话前询问"
            case .immersive: return "沉浸式对话"
            case .manual: return "手工触发式对话"
            }
        }
    }

    /// 待开始的练习（用于「对话前询问」弹窗）。
    struct PendingPractice {
        let summary: ScenarioSummary
        let roleId: String
    }

    /// 外观主题：跟随系统 / 浅色 / 深色。
    enum AppAppearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "跟随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    /// 自动采集时段（支持多个）。
    struct CaptureWindow: Identifiable, Codable, Equatable {
        var id = UUID()
        var start: Date
        var end: Date
    }

    let transcripts: TranscriptStore
    let speech: SpeechCaptureManager
    let api: APIClient
    let auth: AuthStore
    let subscription: SubscriptionManager
    let practiceSpeech: SpeechPracticeManager
    let voice: VoicePromptPlayer
    let realtime: RealtimeVoiceManager

    @Published var filter: TranscriptStore.TimeFilter = .lastHour
    @Published var customStart: Date = Date().addingTimeInterval(-60 * 60)
    @Published var customEnd: Date = Date()
    @Published var learning: LearningResponse?
    @Published var training: TrainingStateResponse?
    @Published var scenario: ScenarioResponse?
    @Published var selectedRoleID = ""
    @Published var roleplay: RoleplayStateResponse?
    @Published var practiceHistory: [PracticeHistoryItem] = []
    @Published var chatMessages: [ChatMessage] = [
        ChatMessage(
            sender: .assistant,
            text: "今天想练哪段真实对话？选一个场景开始，或用底部按钮采集新的日常对话。"
        )
    ]
    @Published var billingAccount: BillingAccountResponse?
    @Published var rechargeOrder: RechargeOrderResponse?
    @Published var planCatalog: [PlanItem] = []
    @Published var myTickets: [SupportTicket] = []
    @Published var audioJobs: [AudioJob] = []
    @Published var isUploadingAudio = false
    @Published var todayScenarios: [ScenarioSummary] = []
    @Published var isLoadingScenarios = false
    @Published var presetCatalog: [PresetScenarioGroup] = []     // 通用场景目录（管理台可配置）
    @Published var isGeneratingPreset = false
    // 对话主界面默认显示双语字幕：AI 句中英同显，用户句先给中文提示
    @Published var showDialogueContent = true
    @Published var autoSpeakAI = true
    @Published var continuousVoiceMode = true
    @Published var isVoiceConversationActive = false
    @Published var guidanceMode: GuidanceMode = .realtime            // 当前会话生效（不可中途切）
    @Published var guidancePreference: GuidancePreference = .ask     // 设置里的偏好
    @Published var conversationMode: ConversationMode = .immersive   // 当前会话生效
    @Published var conversationPreference: ConversationPreference = .ask
    @Published var pendingPractice: PendingPractice?                 // 非空时弹「对话前询问」
    /// 高级会员设置：沉浸式对话时改用「实时语音大模型」直接对话（需求第 4 项）。默认关闭（即文本式对练）。
    @Published var voiceLLMPreference = false
    @Published var showVoiceLLM = false                              // 控制实时语音沉浸式界面呈现
    @Published var autoCaptureEnabled = false
    /// 自动采集时段列表（支持多个）。
    @Published var captureWindows: [CaptureWindow] = []
    @Published var appearance: AppAppearance = .system
    @Published var fontScale: Double = 1.0
    @Published var lastSpokenAnswer = ""
    @Published var trainingAnswer = ""
    @Published var isWorking = false
    @Published var statusMessage = ""

    private var captureScheduleLoop: Task<Void, Never>?
    /// 用户在某采集时段内手动停止后，抑制自动采集直到该时段结束（避免停了又被自动重启）。
    private var autoCaptureSuppressedUntil: Date?
    /// 本次采集开始时拿到的剩余额度（token）与起始已采集字符数，用于采集中定时预估、超额自动停止。
    private var captureRemainingTokens: Int?
    private var captureBaselineChars: Int = 0
    /// 上次重试上传待同步内容的时间（每小时重试一次，直到成功；后端按内容哈希幂等去重）。
    private var lastUploadRetryAt: Date?
    /// 非会员每日采集时长限制：采集开始时刻，用于客户端本地计时与限额（后端看不到采集过程）。
    private var captureStartedAt: Date?
    private var answerTimeoutTask: Task<Void, Never>?
    private var shortcutObserver: NSObjectProtocol?
    private var spokenMessageIDs: Set<String> = []
    private var chattedRoleplayMessageIDs: Set<String> = []
    private let defaults = UserDefaults.standard
    /// 轮到用户说话后，超过该秒数仍未开口则由 AI 主动给提示（要求 12）
    private let answerTimeoutSeconds: UInt64 = 20

    private enum DefaultsKey {
        static let autoCaptureEnabled = "realtalk.autoCaptureEnabled"
        static let autoCaptureStart = "realtalk.autoCaptureStart"
        static let autoCaptureEnd = "realtalk.autoCaptureEnd"
        static let captureWindows = "realtalk.captureWindows"
        static let appearance = "realtalk.appearance"
        static let fontScale = "realtalk.fontScale"
        static let guidancePreference = "realtalk.guidancePreference"
        static let conversationPreference = "realtalk.conversationPreference"
        static let voiceLLMPreference = "realtalk.voiceLLMPreference"
    }

    init() {
        transcripts = TranscriptStore()
        speech = SpeechCaptureManager()
        api = APIClient()
        auth = AuthStore(api: api)
        subscription = SubscriptionManager(api: api)
        practiceSpeech = SpeechPracticeManager()
        voice = VoicePromptPlayer()
        realtime = RealtimeVoiceManager()
        autoCaptureEnabled = defaults.bool(forKey: DefaultsKey.autoCaptureEnabled)
        captureWindows = Self.loadCaptureWindows(defaults)
        if let raw = defaults.string(forKey: DefaultsKey.appearance),
           let value = AppAppearance(rawValue: raw) {
            appearance = value
        }
        let savedFontScale = defaults.double(forKey: DefaultsKey.fontScale)
        if savedFontScale > 0 {
            fontScale = min(max(savedFontScale, 0.85), 1.35)
        }
        if let raw = defaults.string(forKey: DefaultsKey.guidancePreference),
           let pref = GuidancePreference(rawValue: raw) {
            guidancePreference = pref
        }
        if let raw = defaults.string(forKey: DefaultsKey.conversationPreference),
           let pref = ConversationPreference(rawValue: raw) {
            conversationPreference = pref
        }
        voiceLLMPreference = defaults.bool(forKey: DefaultsKey.voiceLLMPreference)

        speech.onSegment = { [weak self] text, date in
            self?.transcripts.addSegment(text: text, at: date)
        }
        practiceSpeech.onUtterance = { [weak self] text in
            Task { @MainActor in
                await self?.submitRoleplayUtterance(text)
            }
        }
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: RealTalkShortcutAction.notification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.object as? String,
                  let action = RealTalkShortcutAction(rawValue: raw)
            else { return }
            Task { @MainActor in
                await self?.handleShortcutAction(action)
            }
        }
    }

    deinit {
        captureScheduleLoop?.cancel()
        answerTimeoutTask?.cancel()
        if let shortcutObserver {
            NotificationCenter.default.removeObserver(shortcutObserver)
        }
    }

    var visibleSegments: [TranscriptSegment] {
        transcripts.segments(for: filter, customStart: customStart, customEnd: customEnd)
    }

    func bootstrap() async {
        transcripts.pruneExpired()
        await auth.restoreSession()
        await subscription.loadProducts()
        await loadBillingAccount()
        await loadPracticeHistory()
        await loadTodayScenarios()
        await loadPlanCatalog()
        startCaptureScheduleLoop()
        await handlePendingShortcutAction()
        await evaluateAutomaticCaptureWindow()
    }

    func handlePendingShortcutAction() async {
        guard let action = RealTalkShortcutAction.consumePending() else { return }
        await handleShortcutAction(action)
    }

    private func handleShortcutAction(_ action: RealTalkShortcutAction) async {
        switch action {
        case .startCapture:
            if speech.isRecording == false {
                await toggleRecording()
            }
        case .stopCapture:
            if speech.isRecording {
                await toggleRecording()
            } else {
                let uploaded = await uploadPending()
                if uploaded > 0 {
                    await loadTodayScenarios()
                }
            }
        }
    }

    /// 拉取今天的场景列表；服务端在已有当天对话却没有场景时会自动生成
    func loadTodayScenarios() async {
        guard let token = auth.token else { return }
        isLoadingScenarios = true
        defer { isLoadingScenarios = false }
        do {
            let response = try await api.todayScenarios(token: token)
            todayScenarios = response.items
            if response.generated {
                appendChat(.assistant, "今日场景已生成，点卡片开练。")
            }
        } catch {
            if statusMessage.isEmpty {
                statusMessage = error.localizedDescription
            }
        }
    }

    func loadScenarioList() async {
        guard let token = auth.token else { return }
        isLoadingScenarios = true
        defer { isLoadingScenarios = false }
        do {
            todayScenarios = try await api.scenarioList(token: token).items
        } catch {
            if statusMessage.isEmpty {
                statusMessage = error.localizedDescription
            }
        }
    }

    /// 加载通用场景目录（主场景 → 子场景标题），供没有录音时直接选场景练口语。
    func loadPresetCatalog() async {
        guard let token = auth.token else { return }
        do {
            presetCatalog = try await api.presetScenarioCatalog(token: token).items
        } catch {
            if statusMessage.isEmpty {
                statusMessage = error.localizedDescription
            }
        }
    }

    /// 选中某个通用子场景：让后端调用 AI 即时生成约 40 句中英对话并落库，成功后返回可对练的场景摘要。
    /// 返回 nil 表示失败（已写入 statusMessage）；成功后由界面弹出选角色对话框进入对练。
    func generatePresetScenario(groupId: String, subId: String) async -> ScenarioSummary? {
        guard let token = auth.token else {
            statusMessage = "请先登录"
            return nil
        }
        isGeneratingPreset = true
        statusMessage = "正在生成场景对话…"
        defer { isGeneratingPreset = false }
        do {
            let scenario = try await api.generatePresetScenario(groupId: groupId, subId: subId, token: token)
            let now = Date()
            statusMessage = ""
            return ScenarioSummary(
                sceneId: scenario.sceneId,
                title: scenario.title,
                summary: scenario.summary,
                roles: scenario.roles,
                lineCount: scenario.lines.count,
                sourceStart: now,
                sourceEnd: now,
                createdAt: now
            )
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    /// 从「今日场景」卡片直接进入练习：拉取场景详情 → 选角色 → 开始对练
    /// 进入练习前：若指导/对话方式设为「每次询问」，先弹窗让用户选择（不可中途切换）。
    func startScenarioPractice(_ summary: ScenarioSummary, roleId: String) async {
        guard auth.token != nil else {
            statusMessage = "请先登录"
            return
        }
        if guidancePreference == .ask || conversationPreference == .ask {
            pendingPractice = PendingPractice(summary: summary, roleId: roleId)
            return
        }
        conversationMode = conversationPreference == .manual ? .manual : .immersive
        guidanceMode = guidancePreference == .final ? .final : .realtime
        await beginPractice(summary, roleId: roleId)
    }

    /// 「对话前询问」弹窗确认后：按所选模式开始，并按需记住偏好。
    func confirmPendingPractice(
        conversation: ConversationMode,
        guidance: GuidanceMode,
        rememberConversation: Bool,
        rememberGuidance: Bool
    ) async {
        guard let pending = pendingPractice else { return }
        conversationMode = conversation
        guidanceMode = guidance
        if rememberConversation {
            conversationPreference = conversation == .manual ? .manual : .immersive
        }
        if rememberGuidance {
            guidancePreference = guidance == .final ? .final : .realtime
        }
        savePracticePreferences()
        pendingPractice = nil
        await beginPractice(pending.summary, roleId: pending.roleId)
    }

    func cancelPendingPractice() {
        pendingPractice = nil
    }

    private func beginPractice(_ summary: ScenarioSummary, roleId: String) async {
        guard let token = auth.token else {
            statusMessage = "请先登录"
            return
        }
        isWorking = true
        do {
            let detail = try await api.scenarioDetail(sceneId: summary.sceneId, token: token)
            scenario = detail
            selectedRoleID = roleId
            isWorking = false
            appendChat(.user, "练习：\(summary.title)（扮演\(roleName(roleId))）")
            if shouldUseVoiceLLM {
                await beginVoiceLLMPractice()
            } else {
                await startRoleplay()
            }
        } catch {
            isWorking = false
            statusMessage = error.localizedDescription
        }
    }

    /// 高级会员沉浸式 + 实时语音大模型：在后端建立 roleplay 会话拿 session_id，再用 WebSocket 直接语音对话。
    /// 不走文本逐句对练（不设置 roleplay 状态），结束后由语音模型给出评分与分析。
    private func beginVoiceLLMPractice() async {
        guard let token = auth.token, let scene = scenario, selectedRoleID.isEmpty == false else {
            statusMessage = "请先选择场景与角色"
            return
        }
        // 停掉文本式语音/识别，避免与实时语音抢占麦克风
        practiceSpeech.stop(emit: false)
        voice.stop()

        isWorking = true
        do {
            // 复用 /roleplay/start 在后端建立会话（仅取 session_id 供实时语音 WS 使用）
            let range = transcripts.dateRange(for: filter, customStart: customStart, customEnd: customEnd)
            let state = try await api.startRoleplay(
                start: range.0,
                end: range.1,
                selectedRole: selectedRoleID,
                sceneId: scene.sceneId,
                segments: [],
                token: token
            )
            isWorking = false
            statusMessage = "实时语音对练已开始"
            showVoiceLLM = true
            await realtime.start(token: token, sessionId: state.sessionId, scenarioTitle: scene.title)
            await loadPracticeHistory()
        } catch {
            isWorking = false
            statusMessage = error.localizedDescription
        }
    }

    func toggleRecording() async {
        if speech.isRecording {
            // 若在自动采集时段内手动停止：抑制本时段的自动重启，直到该时段结束
            if autoCaptureEnabled, let end = currentAutoWindowEnd() {
                autoCaptureSuppressedUntil = end
            }
            captureRemainingTokens = nil
            commitCaptureSeconds()
            speech.stop(savePartial: true)
            statusMessage = "已停止采集，正在发送给后台并生成场景…"
            try? await Task.sleep(nanoseconds: 400_000_000)
            let uploaded = await uploadPending()
            if uploaded > 0 {
                await loadTodayScenarios()
            }
        } else {
            await startCaptureWithQuotaCheck()
        }
    }

    /// 待同步内容的总字符数（≈token），用于采集中的额度预估。
    private var pendingCharCount: Int {
        transcripts.pendingUpload.reduce(0) { $0 + $1.text.count }
    }

    // MARK: 非会员每日采集时长限额（客户端本地强制；后端不感知采集过程）

    private var isNonMember: Bool { auth.user?.effectiveTier == "free" }
    private var nonmemberCaptureSecondsLimit: Int { billingAccount?.nonmemberLimits?.dailyCaptureSeconds ?? 300 }

    private func captureDayKey() -> String {
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// 今日已采集秒数（跨天自动归零）。
    private var capturedSecondsToday: Int {
        guard defaults.string(forKey: "realtalk.captureSecondsDay") == captureDayKey() else { return 0 }
        return defaults.integer(forKey: "realtalk.captureSecondsValue")
    }

    private func addCapturedSeconds(_ seconds: Int) {
        guard seconds > 0 else { return }
        let base = capturedSecondsToday
        defaults.set(captureDayKey(), forKey: "realtalk.captureSecondsDay")
        defaults.set(base + seconds, forKey: "realtalk.captureSecondsValue")
    }

    /// 把本次采集已进行的时长累计进今日计数（停止采集时调用）。
    private func commitCaptureSeconds() {
        if let started = captureStartedAt {
            addCapturedSeconds(Int(Date().timeIntervalSince(started)))
        }
        captureStartedAt = nil
    }

    /// 采集中定时检查：非会员今日采集时长超限则自动停止并提交。
    private func enforceCaptureSecondsLimit() async {
        guard speech.isRecording, isNonMember else { return }
        let limit = nonmemberCaptureSecondsLimit
        guard limit > 0 else { return }
        let elapsed = captureStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        guard capturedSecondsToday + elapsed >= limit else { return }
        commitCaptureSeconds()
        speech.stop(savePartial: true)
        captureRemainingTokens = nil
        statusMessage = "今日免费采集时长已用完，已停止并提交；升级会员可不限时长"
        let uploaded = await uploadPending()
        if uploaded > 0 { await loadTodayScenarios() }
    }

    /// 开始采集前查询剩余额度：超额则拦截不采集；额度不足则提示但仍允许；记录额度用于采集中自动停止。
    private func startCaptureWithQuotaCheck() async {
        captureRemainingTokens = nil
        // 非会员每日采集时长限额（客户端本地强制；后端看不到采集过程）
        if isNonMember, nonmemberCaptureSecondsLimit > 0, capturedSecondsToday >= nonmemberCaptureSecondsLimit {
            statusMessage = "今日免费采集时长已用完，升级会员可不限时长，或明天再来"
            return
        }
        if let token = auth.token, let quota = try? await api.captureQuota(token: token) {
            if quota.canCapture == false {
                statusMessage = quota.message
                return
            }
            captureRemainingTokens = quota.remainingTokens
            captureBaselineChars = pendingCharCount
            await speech.start()
            captureStartedAt = Date()
            statusMessage = quota.message.isEmpty ? "正在采集真实对话" : quota.message
        } else {
            await speech.start()
            captureStartedAt = Date()
            statusMessage = "正在采集真实对话"
        }
    }

    /// 每小时重试一次未成功上传的待同步内容，直到成功（后端按内容哈希幂等，不会生成重复场景）。
    private func retryPendingUploadsIfNeeded() async {
        guard speech.isRecording == false, auth.token != nil else { return }
        guard transcripts.pendingUpload.isEmpty == false else { return }
        let now = Date()
        if let last = lastUploadRetryAt, now.timeIntervalSince(last) < 3600 { return }
        lastUploadRetryAt = now
        let uploaded = await uploadPending()
        if uploaded > 0 { await loadTodayScenarios() }
    }

    /// 采集中定时预估：已采集字符数超过开始时的剩余额度则自动停止并提交生成场景。
    private func enforceCaptureQuotaDuringRecording() async {
        guard speech.isRecording, let remaining = captureRemainingTokens else { return }
        let collected = max(0, pendingCharCount - captureBaselineChars)
        guard collected >= remaining else { return }
        captureRemainingTokens = nil
        commitCaptureSeconds()
        speech.stop(savePartial: true)
        statusMessage = "已达当月额度，已自动停止采集并提交生成场景"
        let uploaded = await uploadPending()
        if uploaded > 0 { await loadTodayScenarios() }
    }

    func saveCaptureSchedule() {
        defaults.set(autoCaptureEnabled, forKey: DefaultsKey.autoCaptureEnabled)
        if let data = try? JSONEncoder().encode(captureWindows) {
            defaults.set(data, forKey: DefaultsKey.captureWindows)
        }
        Task { await evaluateAutomaticCaptureWindow() }
    }

    /// 新增一个采集时段（默认 9:00–18:00）。
    func addCaptureWindow() {
        let cal = Calendar.current
        let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        let end = cal.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
        captureWindows.append(CaptureWindow(start: start, end: end))
        saveCaptureSchedule()
    }

    func removeCaptureWindow(_ id: UUID) {
        captureWindows.removeAll { $0.id == id }
        saveCaptureSchedule()
    }

    private static func loadCaptureWindows(_ defaults: UserDefaults) -> [CaptureWindow] {
        if let data = defaults.data(forKey: DefaultsKey.captureWindows),
           let windows = try? JSONDecoder().decode([CaptureWindow].self, from: data) {
            return windows
        }
        // 旧版单时段迁移
        let cal = Calendar.current
        let start = defaults.object(forKey: DefaultsKey.autoCaptureStart) as? Date
            ?? cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        let end = defaults.object(forKey: DefaultsKey.autoCaptureEnd) as? Date
            ?? cal.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
        return [CaptureWindow(start: start, end: end)]
    }

    func savePracticePreferences() {
        defaults.set(fontScale, forKey: DefaultsKey.fontScale)
        defaults.set(guidancePreference.rawValue, forKey: DefaultsKey.guidancePreference)
        defaults.set(conversationPreference.rawValue, forKey: DefaultsKey.conversationPreference)
        defaults.set(voiceLLMPreference, forKey: DefaultsKey.voiceLLMPreference)
        defaults.set(appearance.rawValue, forKey: DefaultsKey.appearance)
    }

    /// 是否高级会员：实时语音大模型对练是高级会员专属能力。
    var isPremium: Bool { auth.user?.effectiveTier == "premium" }

    /// 本次是否走「实时语音大模型」：仅高级会员 + 沉浸式 + 已开启偏好（手工触发式不支持）。
    var shouldUseVoiceLLM: Bool {
        isPremium && conversationMode == .immersive && voiceLLMPreference
    }

    /// 结束实时语音对练并请求评分（保留界面以展示评分）。
    func endVoiceLLMPractice() {
        realtime.end()
    }

    /// 关闭实时语音沉浸式界面（评分已展示或用户放弃）。
    func dismissVoiceLLM() {
        realtime.cancel()
        showVoiceLLM = false
    }

    /// 上传待同步的转写，返回成功上传的条数（-1=出错，0=无内容）。
    @discardableResult
    func uploadPending() async -> Int {
        guard let token = auth.token else {
            statusMessage = "请先登录后同步"
            return 0
        }

        let pending = transcripts.pendingUpload
        guard pending.isEmpty == false else {
            statusMessage = "没有待同步内容"
            return 0
        }

        do {
            statusMessage = "已发布给后台，正在生成场景…（\(pending.count) 句）"
            let response = try await api.uploadCaptureSegments(pending, token: token)
            transcripts.markUploaded(ids: pending.map(\.id))
            statusMessage = "已生成 \(response.generated) 个场景，可在列表中选择练习"
            return response.acceptedItems
        } catch {
            statusMessage = "上传失败：\(error.localizedDescription)"
            return -1
        }
    }

    /// 把用户输入的文字当作"今天的真实对话"录入（模拟器无麦克风时的回退路径）。
    /// 按中英文标点拆句后上传，再触发今日场景生成。
    func ingestTypedConversation(_ raw: String) async {
        let body = raw
            .replacingOccurrences(of: "录入对话", with: "")
            .replacingOccurrences(of: "录入", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "：: \n"))
        guard body.isEmpty == false else {
            appendChat(.assistant, "发：录入对话 + 今天说过的话。")
            return
        }
        let parts = body
            .components(separatedBy: CharacterSet(charactersIn: "。！？!?；;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
        let sentences = parts.isEmpty ? [body] : parts
        let base = Date()
        for (i, s) in sentences.enumerated() {
            transcripts.addSegment(text: s, at: base.addingTimeInterval(Double(i)), source: "typed")
        }
        let uploaded = await uploadPending()
        if uploaded > 0 {
            appendChat(.assistant, "已录入 \(uploaded) 句，生成场景中…")
            await loadTodayScenarios()
        } else if uploaded == 0 {
            appendChat(.assistant, "没能录入，换一段再试。")
        }
    }

    func generateLearning() async {
        guard let token = auth.token else {
            statusMessage = "请先登录"
            return
        }

        let selected = visibleSegments.reversed()
        guard selected.isEmpty == false else {
            statusMessage = "当前时间范围没有对话"
            return
        }

        isWorking = true
        defer { isWorking = false }

        let range = transcripts.dateRange(for: filter, customStart: customStart, customEnd: customEnd)
        do {
            learning = try await api.generateLearning(
                start: range.0,
                end: range.1,
                segments: Array(selected),
                token: token
            )
            statusMessage = "学习内容已生成"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func startTraining() async {
        guard let token = auth.token else {
            statusMessage = "请先登录"
            return
        }

        let selected = visibleSegments.reversed()
        guard selected.isEmpty == false else {
            statusMessage = "当前时间范围没有对话"
            return
        }

        isWorking = true
        defer { isWorking = false }

        let range = transcripts.dateRange(for: filter, customStart: customStart, customEnd: customEnd)
        do {
            training = try await api.startTraining(
                start: range.0,
                end: range.1,
                segments: Array(selected),
                token: token
            )
            trainingAnswer = ""
            statusMessage = "训练已开始"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func submitTrainingAnswer() async {
        guard let token = auth.token else {
            statusMessage = "请先登录"
            return
        }
        guard let training else {
            statusMessage = "请先开始训练"
            return
        }
        guard trainingAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            statusMessage = "请输入答案"
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            self.training = try await api.submitTrainingAnswer(
                sessionId: training.sessionId,
                answer: trainingAnswer,
                token: token
            )
            trainingAnswer = ""
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    var roleCandidates: [ScenarioRole] {
        scenario?.roles.filter(\.isUserCandidate) ?? []
    }

    func roleName(_ roleID: String) -> String {
        scenario?.roles.first(where: { $0.id == roleID })?.name ?? roleID
    }

    func generateScenario() async {
        guard let token = auth.token else {
            statusMessage = "请先登录"
            return
        }

        let selected = visibleSegments.reversed()
        guard selected.isEmpty == false else {
            statusMessage = "当前时间范围没有对话"
            return
        }

        isWorking = true
        defer { isWorking = false }

        let range = transcripts.dateRange(for: filter, customStart: customStart, customEnd: customEnd)
        do {
            let generated = try await api.generateScenario(
                start: range.0,
                end: range.1,
                segments: Array(selected),
                token: token
            )
            scenario = generated
            roleplay = nil
            isVoiceConversationActive = false
            practiceSpeech.stop(emit: false)
            voice.stop()
            selectedRoleID = generated.roles.first(where: { $0.isUserCandidate })?.id ?? generated.roles.first?.id ?? ""
            spokenMessageIDs.removeAll()
            statusMessage = "场景已生成"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func startRoleplay() async {
        guard let token = auth.token else {
            statusMessage = "请先登录"
            return
        }
        guard selectedRoleID.isEmpty == false else {
            statusMessage = "请选择练习角色"
            return
        }

        if speech.isRecording {
            speech.stop(savePartial: true)
        }
        practiceSpeech.stop(emit: false)
        voice.stop()
        isVoiceConversationActive = true
        autoSpeakAI = true
        lastSpokenAnswer = ""
        spokenMessageIDs.removeAll()

        let selected = visibleSegments.reversed()
        let range = transcripts.dateRange(for: filter, customStart: customStart, customEnd: customEnd)

        isWorking = true
        defer { isWorking = false }

        do {
            let state = try await api.startRoleplay(
                start: range.0,
                end: range.1,
                selectedRole: selectedRoleID,
                sceneId: scenario?.sceneId,
                segments: Array(selected),
                token: token
            )
            scenario = state.scenario
            handleRoleplayState(state)
            statusMessage = "语音对话已开始"
            await loadPracticeHistory()
        } catch {
            isVoiceConversationActive = false
            statusMessage = error.localizedDescription
        }
    }

    func toggleVoiceConversation() async {
        if roleplay == nil {
            guard scenario != nil else {
                // 引导放进聊天流（appendChat 会去重连续相同消息，避免反复点击堆叠）
                appendChat(.assistant, "先选个场景：点上方卡片，或用底部按钮采集。")
                return
            }
            await startRoleplay()
            return
        }

        if roleplay?.completed == true {
            await startRoleplay()
            return
        }

        if isVoiceConversationActive {
            pauseVoiceConversation()
        } else {
            isVoiceConversationActive = true
            statusMessage = "语音对话已继续"
            await listenForNextRoleplayTurn()
        }
    }

    func pauseVoiceConversation() {
        isVoiceConversationActive = false
        cancelAnswerTimeout()
        practiceSpeech.stop(emit: false)
        voice.stop()
        statusMessage = "语音对话已暂停"
    }

    func switchRole() {
        let candidates = roleCandidates
        guard candidates.count > 1 else {
            statusMessage = "当前场景没有可对换的角色"
            return
        }

        let currentIndex = candidates.firstIndex(where: { $0.id == selectedRoleID }) ?? 0
        let nextRole = candidates[(currentIndex + 1) % candidates.count]
        selectedRoleID = nextRole.id
        roleplay = nil
        lastSpokenAnswer = ""
        spokenMessageIDs.removeAll()
        pauseVoiceConversation()
        statusMessage = "已切换为：\(nextRole.name)"
    }

    func switchRoleAndRestart() async {
        switchRole()
        await startRoleplay()
    }

    func submitRoleplayUtterance(_ text: String) async {
        guard let token = auth.token else {
            statusMessage = "请先登录"
            return
        }
        guard let roleplay else {
            statusMessage = "请先开始口语对练"
            return
        }

        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard answer.isEmpty == false else { return }

        cancelAnswerTimeout()

        if isPracticeHelpRequest(answer) {
            appendChat(.user, answer)
            await providePracticeHint(for: answer)
            return
        }

        lastSpokenAnswer = answer
        appendChat(.user, answer)

        isWorking = true
        defer { isWorking = false }

        do {
            let state = try await api.submitRoleplayMessage(
                sessionId: roleplay.sessionId,
                message: answer,
                guidanceMode: guidanceMode.rawValue,
                token: token
            )
            let feedback = state.latestFeedback?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let feedback, feedback.isEmpty == false {
                statusMessage = feedback
                if guidanceMode == .realtime || state.completed {
                    appendChat(.assistant, feedback)
                }
                handleRoleplayState(state, spokenPreface: feedback)
            } else {
                statusMessage = "继续对话"
                handleRoleplayState(state)
            }
            await loadPracticeHistory()
        } catch {
            isVoiceConversationActive = false
            statusMessage = error.localizedDescription
        }
    }

    /// 重新对练当前场景：完成后可在沉浸式界面一键重玩。
    func replayScenario() async {
        guard scenario != nil, selectedRoleID.isEmpty == false else {
            statusMessage = "先选个场景再开始"
            return
        }
        roleplay = nil
        await startRoleplay()
    }

    /// 「结束后指导」模式下按需取最终评分与建议；中途退出也能拿到结果。
    func requestFinalEvaluation() async {
        guard let token = auth.token, let roleplay else {
            statusMessage = "还没有进行中的对练"
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let state = try await api.evaluateRoleplay(sessionId: roleplay.sessionId, token: token)
            self.roleplay = state
            if let feedback = state.latestFeedback?.trimmingCharacters(in: .whitespacesAndNewlines),
               feedback.isEmpty == false {
                appendChat(.assistant, feedback)
                if autoSpeakAI { voice.speak(feedback) }
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadPracticeHistory() async {
        guard let token = auth.token else { return }
        do {
            practiceHistory = try await api.practiceHistory(token: token).items
        } catch {
            if statusMessage.isEmpty {
                statusMessage = error.localizedDescription
            }
        }
    }

    func loadBillingAccount() async {
        guard let token = auth.token else { return }
        do {
            let account = try await api.billingAccount(token: token)
            billingAccount = account
            auth.applyBillingUser(account.user)
        } catch {
            if statusMessage.isEmpty {
                statusMessage = error.localizedDescription
            }
        }
    }

    func loadPlanCatalog() async {
        do {
            planCatalog = try await api.planCatalog().items
        } catch {
            if statusMessage.isEmpty { statusMessage = error.localizedDescription }
        }
    }

    /// 当前用户可选的套餐（按档位）：非会员=全部；基础=延长基础+升级高级；高级=延长高级。
    var availablePlans: [PlanItem] {
        switch auth.user?.effectiveTier {
        case "premium": return planCatalog.filter { $0.tier == "premium" }
        case "basic": return planCatalog  // 基础可续基础、也可升级高级
        default: return planCatalog       // 非会员可选全部
        }
    }

    func loadMyTickets() async {
        guard let token = auth.token else { return }
        do { myTickets = try await api.mySupportTickets(token: token).items }
        catch { if statusMessage.isEmpty { statusMessage = error.localizedDescription } }
    }

    /// 提交客服工单（如基础升高级后申请原基础会员退款）。
    @discardableResult
    func submitSupportTicket(category: String, subject: String, body: String) async -> Bool {
        guard let token = auth.token else { statusMessage = "请先登录"; return false }
        do {
            _ = try await api.createSupportTicket(category: category, subject: subject, body: body, token: token)
            await loadMyTickets()
            statusMessage = "工单已提交，我们会尽快处理"
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    /// 开通会员：生成套餐支付订单（微信/支付宝），支付成功后激活会员
    func subscribe(planId: String, method: String) async {
        guard let token = auth.token else {
            statusMessage = "请先登录"
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            rechargeOrder = try await api.createRecharge(amountCents: 0, method: method, planId: planId, token: token)
            statusMessage = rechargeOrder?.message ?? "订单已创建，请完成支付"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadAudioJobs() async {
        guard let token = auth.token else { return }
        do {
            audioJobs = try await api.audioJobs(token: token).items
        } catch {
            if statusMessage.isEmpty { statusMessage = error.localizedDescription }
        }
    }

    /// 高级会员：上传录音文件（手机本地或录音笔下载的文件）生成场景
    func uploadRecording(fileURL: URL) async {
        guard let token = auth.token else {
            statusMessage = "请先登录"
            return
        }
        // App 本地判断文件大小与时长（无需后端往返），超限直接拒绝
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        if size > 300 * 1024 * 1024 {
            statusMessage = "文件过大，最大 300MB"
            return
        }
        if let duration = try? await AVURLAsset(url: fileURL).load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 6 * 3600 {
                statusMessage = "音频过长，最长 6 小时"
                return
            }
        }

        isUploadingAudio = true
        defer { isUploadingAudio = false }

        // App 计算文件哈希做上传前去重预检：同文件已生成过场景则直接复用，省去整段上传
        if let hash = Self.fileSHA256(fileURL),
           let pre = try? await api.audioPrecheck(fileHash: hash, token: token),
           pre.duplicate {
            statusMessage = "该录音此前已生成过场景，已直接复用，无需重复上传"
            await loadAudioJobs()
            await loadTodayScenarios()
            return
        }

        do {
            // 断点续传上传，网络波动自动续传，适合大文件
            _ = try await api.uploadAudioResumable(fileURL: fileURL, token: token) { [weak self] fraction in
                Task { @MainActor in
                    self?.statusMessage = "上传中 \(Int(fraction * 100))%"
                }
            }
            statusMessage = "上传成功，正在转写生成场景"
            await loadAudioJobs()
            // 处理是异步的，轮询直到完成
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await loadAudioJobs()
                let active = audioJobs.contains { ["pending", "transcribing", "generating"].contains($0.status) }
                if active == false { break }
            }
            await loadTodayScenarios()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// 流式计算文件 SHA-256（与后端一致），用于上传前去重预检。
    private static func fileSHA256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1024 * 1024), chunk.isEmpty == false {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func createRecharge(amountCents: Int, method: String) async {
        guard let token = auth.token else {
            statusMessage = "请先登录"
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            rechargeOrder = try await api.createRecharge(amountCents: amountCents, method: method, token: token)
            statusMessage = rechargeOrder?.message ?? "充值订单已创建"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func confirmRecharge() async {
        guard let token = auth.token, let rechargeOrder else {
            statusMessage = "请先创建充值订单"
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let account = try await api.confirmRecharge(orderId: rechargeOrder.orderId, token: token)
            billingAccount = account
            auth.applyBillingUser(account.user)
            self.rechargeOrder = nil
            statusMessage = "支付成功，当前为\(account.user.tierName)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func replayLastAI() {
        guard let message = roleplay?.messages.last(where: { $0.speaker == "ai" }) else { return }
        voice.speak(message.content)
    }

    func interruptAIAndContinue() {
        voice.stop()
        Task { await listenForNextRoleplayTurn() }
    }

    private func handleRoleplayState(_ state: RoleplayStateResponse, spokenPreface: String? = nil) {
        roleplay = state
        scenario = state.scenario
        selectedRoleID = state.selectedRole
        if state.completed {
            isVoiceConversationActive = false
            cancelAnswerTimeout()
            practiceSpeech.stop(emit: false)
        }

        let newAIMessages = state.messages.filter { $0.speaker == "ai" && spokenMessageIDs.contains($0.id) == false }
        newAIMessages.forEach { spokenMessageIDs.insert($0.id) }
        for message in newAIMessages where chattedRoleplayMessageIDs.contains(message.id) == false {
            chattedRoleplayMessageIDs.insert(message.id)
            let line = state.scenario.lines.first(where: { $0.english == message.content })
            if showDialogueContent {
                appendChat(.assistant, "\(message.content)\n\n中文：\(message.translation ?? "")")
            } else {
                appendChat(.assistant, "我正在扮演 \(roleName(message.role))。请听语音回应。")
            }
            if let next = state.nextLine, next.index == (line?.index ?? -1) + 1 {
                appendChat(.system, "轮到你：\(next.sourceText)")
            }
        }
        if let next = state.nextLine, newAIMessages.isEmpty {
            appendChat(.system, "轮到你：\(next.sourceText)")
        }

        guard autoSpeakAI, newAIMessages.isEmpty == false else {
            if let spokenPreface {
                voice.speak(spokenPreface) { [weak self] in
                    Task { @MainActor in
                        await self?.listenForNextRoleplayTurn()
                    }
                }
            } else {
                Task { @MainActor in
                    await listenForNextRoleplayTurn()
                }
            }
            return
        }

        let spoken = [spokenPreface].compactMap { $0 } + newAIMessages.map(\.content)
        voice.speak(spoken) { [weak self] in
            Task { @MainActor in
                await self?.listenForNextRoleplayTurn()
            }
        }
    }

    private func listenForNextRoleplayTurn() async {
        guard isVoiceConversationActive else { return }
        // 手工触发式：不自动开麦，等用户长按说话
        guard conversationMode == .immersive else { return }
        guard continuousVoiceMode else { return }
        guard roleplay?.completed == false, roleplay?.nextLine != nil else { return }
        guard practiceSpeech.isListening == false, voice.isSpeaking == false else { return }
        await practiceSpeech.start()
        scheduleAnswerTimeout()
    }

    // MARK: 手工触发式对话（长按说话，滑动取消/发送）

    /// 长按开始：停掉 AI、开麦但不自动提交（由松手决定）。
    func beginManualUtterance() async {
        guard isVoiceConversationActive else { return }
        cancelAnswerTimeout()
        voice.stop()
        guard practiceSpeech.isListening == false else { return }
        await practiceSpeech.start(autoSubmit: false)
    }

    /// 松手发送：把已识别内容提交给后端（经 onUtterance → submitRoleplayUtterance）。
    func sendManualUtterance() {
        practiceSpeech.stop(emit: true)
    }

    /// 滑到取消区：丢弃本次，不提交。
    func cancelManualUtterance() {
        practiceSpeech.stop(emit: false)
    }

    /// 用户长时间没开口时，AI 主动暂停并给出指导，再继续等待回答
    private func scheduleAnswerTimeout() {
        cancelAnswerTimeout()
        answerTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.answerTimeoutSeconds ?? 20) * 1_000_000_000)
            guard Task.isCancelled == false else { return }
            await self?.handleAnswerTimeout()
        }
    }

    private func cancelAnswerTimeout() {
        answerTimeoutTask?.cancel()
        answerTimeoutTask = nil
    }

    private func handleAnswerTimeout() async {
        guard isVoiceConversationActive else { return }
        guard roleplay?.completed == false, let next = roleplay?.nextLine else { return }
        guard practiceSpeech.partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // 用户正在说，再宽限一轮
            scheduleAnswerTimeout()
            return
        }
        practiceSpeech.stop(emit: false)
        appendChat(.assistant, "提示：\(next.sourceText)\n试着说：\(next.english)")
        // 下一句提示仅在指导区展示，不做 AI 语音播报（item 3）
        await listenForNextRoleplayTurn()
    }

    private func appendChat(_ sender: ChatMessage.Sender, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        if chatMessages.last?.sender == sender && chatMessages.last?.text == trimmed {
            return
        }
        chatMessages.append(ChatMessage(sender: sender, text: trimmed))
    }

    private func appendCurrentHint() {
        guard let next = roleplay?.nextLine else {
            appendChat(.assistant, "现在还没有进行中的练习。你可以说：我想练习今天中午订餐时与服务员的对话。")
            return
        }
        appendChat(.assistant, "中文提示：\(next.sourceText)\n可以这样说：\(next.english)")
    }

    private func providePracticeHint(for prompt: String) async {
        await askBackendAI(prompt, fallback: { [weak self] in
            self?.appendCurrentHint()
        })

        guard isVoiceConversationActive else { return }
        guard roleplay?.completed == false, roleplay?.nextLine != nil else { return }
        // 下一句提示仅在指导区展示，不做 AI 语音播报（item 3）
        await listenForNextRoleplayTurn()
    }

    private func isPracticeHelpRequest(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.isEmpty == false else { return false }

        if normalized.contains("不知道")
            || normalized.contains("提示")
            || normalized.contains("怎么说")
            || normalized.contains("帮我")
        {
            return true
        }

        return normalized == "hint"
            || normalized == "help"
            || normalized.contains("i don't know")
            || normalized.contains("i dont know")
            || normalized.contains("how do i say")
            || normalized.contains("what should i say")
            || normalized.contains("can you help")
    }

    private func appendPracticeSummary() {
        guard let roleplay else {
            appendChat(.assistant, "还没有练习记录。")
            return
        }
        pauseVoiceConversation()
        let corrections = roleplay.messages
            .filter { $0.speaker == "user" }
            .map { message in
                "中文：\(message.translation ?? "")\n你说：\(message.content)\n建议：\(message.feedback ?? "继续保持。")"
            }
            .joined(separator: "\n\n")
        appendChat(.assistant, corrections.isEmpty ? "这轮还没有你的口语回答。" : "本轮纠错总结：\n\n\(corrections)")
    }

    private func askBackendAI(_ prompt: String, fallback: @escaping () -> Void) async {
        guard let token = auth.token else {
            fallback()
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let response = try await api.aiChat(
                message: prompt,
                history: aiChatHistory(),
                sceneId: scenario?.sceneId,
                sessionId: roleplay?.sessionId,
                token: token
            )
            appendChat(.assistant, response.reply)
        } catch {
            statusMessage = error.localizedDescription
            fallback()
        }
    }

    private func aiChatHistory() -> [AIChatWireMessage] {
        chatMessages.suffix(20).compactMap { message in
            let role: String
            switch message.sender {
            case .user:
                role = "user"
            case .assistant:
                role = "assistant"
            case .system:
                role = "system"
            }
            return AIChatWireMessage(role: role, content: message.text)
        }
    }

    private func configureConversationRange(from prompt: String) {
        if prompt.contains("中午") || prompt.contains("午餐") || prompt.contains("订餐") {
            let calendar = Calendar.current
            let now = Date()
            customStart = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(-3 * 60 * 60)
            customEnd = calendar.date(bySettingHour: 14, minute: 30, second: 0, of: now) ?? now
            filter = .custom
        } else if prompt.contains("今天") {
            filter = .today
        }
    }

    private func startCaptureScheduleLoop() {
        guard captureScheduleLoop == nil else { return }
        captureScheduleLoop = Task { [weak self] in
            while Task.isCancelled == false {
                await self?.evaluateAutomaticCaptureWindow()
                await self?.enforceCaptureQuotaDuringRecording()
                await self?.enforceCaptureSecondsLimit()
                await self?.retryPendingUploadsIfNeeded()
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    private func evaluateAutomaticCaptureWindow() async {
        guard autoCaptureEnabled else { return }
        guard isVoiceConversationActive == false else { return }

        // 抑制期过了就清除
        if let until = autoCaptureSuppressedUntil, Date() >= until {
            autoCaptureSuppressedUntil = nil
        }

        if isNowInsideAutomaticCaptureWindow() {
            // 用户手动停止过本时段：本时段内不再自动重启
            if autoCaptureSuppressedUntil != nil { return }
            if speech.isRecording == false {
                // 自动采集同样先校验额度，超额则不启动并提示
                await startCaptureWithQuotaCheck()
            }
        } else if speech.isRecording {
            commitCaptureSeconds()
            speech.stop(savePartial: true)
            statusMessage = "已按默认时间结束采集"
            let uploaded = await uploadPending()
            if uploaded > 0 {
                await loadTodayScenarios()
            }
        }
    }

    private func isNowInsideAutomaticCaptureWindow(now: Date = Date()) -> Bool {
        let calendar = Calendar.current
        let current = minutesSinceStartOfDay(now, calendar: calendar)
        // 任一时段命中即视为在采集窗口内（支持多个时段）
        return captureWindows.contains { window in
            let start = minutesSinceStartOfDay(window.start, calendar: calendar)
            let end = minutesSinceStartOfDay(window.end, calendar: calendar)
            if start == end { return false }
            if start < end { return current >= start && current < end }
            return current >= start || current < end  // 跨天时段
        }
    }

    private func minutesSinceStartOfDay(_ date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    /// 当前时刻所在采集时段的结束时间（今天）；不在任何时段返回 nil。
    private func currentAutoWindowEnd(now: Date = Date()) -> Date? {
        let calendar = Calendar.current
        let current = minutesSinceStartOfDay(now, calendar: calendar)
        for window in captureWindows {
            let start = minutesSinceStartOfDay(window.start, calendar: calendar)
            let end = minutesSinceStartOfDay(window.end, calendar: calendar)
            if start == end { continue }
            let inside = start < end ? (current >= start && current < end) : (current >= start || current < end)
            guard inside else { continue }
            let comps = calendar.dateComponents([.hour, .minute], from: window.end)
            var endToday = calendar.date(bySettingHour: comps.hour ?? 0, minute: comps.minute ?? 0, second: 0, of: now) ?? now
            if start >= end { endToday = calendar.date(byAdding: .day, value: 1, to: endToday) ?? endToday } // 跨天时段，结束在次日
            return endToday
        }
        return nil
    }
}
