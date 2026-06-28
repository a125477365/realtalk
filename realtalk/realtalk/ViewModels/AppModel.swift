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

    /// 对话方式（当前会话生效，不可中途切换）。voice = 实时语音大模型直连（高级会员专属）。
    enum ConversationMode: String { case immersive, manual, voice }

    /// 对话方式偏好：可选「每次开始对话前询问」。voice（语音模型对话）仅高级会员可选。
    enum ConversationPreference: String, CaseIterable, Identifiable {
        case ask
        case voice
        case immersive
        case manual

        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: return "每次开始对话前询问"
            case .voice: return "语音模型对话"
            case .immersive: return "沉浸式对话"
            case .manual: return "手工触发式对话"
            }
        }
    }

    /// 待开始的练习（用于「对话前询问」弹窗）。
    struct PendingPractice {
        let summary: ScenarioSummary
        let roleId: String
        var resume: Bool = false
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
    let stream = RoleplayStreamManager()
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
    @Published var presetCatalog: [PresetSceneGroup] = []     // 通用场景：运维预置的全局场景（按主场景分组）
    // 对话主界面默认显示双语字幕：AI 句中英同显，用户句先给中文提示
    @Published var showDialogueContent = true
    @Published var isVoiceConversationActive = false
    /// 超时未答时 AI 给出的「可以这样说」英文提示，显示在沉浸式指导区（不再只进不可见的主聊天流）。
    @Published var practiceHintText: String?
    @Published var guidanceMode: GuidanceMode = .realtime            // 当前会话生效（不可中途切）
    @Published var guidancePreference: GuidancePreference = .ask     // 设置里的偏好
    @Published var conversationMode: ConversationMode = .immersive   // 当前会话生效
    @Published var conversationPreference: ConversationPreference = .ask
    @Published var pendingPractice: PendingPractice?                 // 非空时弹「对话前询问」
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
    // AI 朗读音色（后端 TTS）
    @Published var ttsVoices: [String] = []
    @Published var ttsCurrentVoice = ""
    @Published var ttsConfigured = false
    /// 中断流程的系统/模型/额度异常：弹失败提示框（不像 statusMessage 只在主界面显示）。
    @Published var failureAlert: FailureAlert?

    struct FailureAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// 处理中（等待后台）：用于全局禁用其它操作按钮，避免在生成/对练中误触发新请求。
    var isBusy: Bool { isWorking }

    /// 弹出失败提示框，并同步到顶部状态文案。message 为空时给出兜底说明。
    func presentFailure(_ message: String, title: String = "操作未完成") {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = text.isEmpty ? "发生未知错误，请稍后重试。" : text
        failureAlert = FailureAlert(title: title, message: shown)
        statusMessage = shown
    }

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
    /// 用户是否已主动退出对话界面：退出后即使后台回包也不再播报 AI 语音/续听。
    private var conversationExited = false
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

        speech.onSegment = { [weak self] text, date in
            self?.transcripts.addSegment(text: text, at: date)
        }
        practiceSpeech.onAudioUtterance = { [weak self] url in
            Task { @MainActor in
                await self?.submitRoleplayAudio(url)
            }
        }
        // AI 台词改用后端 TTS（可选音色、口音更自然）；后端不可用时 VoicePromptPlayer 自动回退本机合成
        voice.audioProvider = { [weak self] text, cache in
            guard let self else { return nil }
            return await self.fetchTTSAudio(text, cache: cache)
        }
        // 沉浸式后端语音流（WS）：整段对话由流驱动，结果回来直接刷新对练状态
        stream.onResultState = { [weak self] data in
            Task { @MainActor in self?.applyStreamState(data) }
        }
        stream.onResultMessage = { [weak self] msg in
            Task { @MainActor in self?.statusMessage = msg }
        }
        stream.onStatus = { [weak self] msg in
            Task { @MainActor in self?.statusMessage = msg }
        }
        stream.onCompleted = { [weak self] in
            Task { @MainActor in self?.isVoiceConversationActive = false }
        }
        stream.onError = { [weak self] msg in
            Task { @MainActor in
                guard let self else { return }
                self.isVoiceConversationActive = false
                self.stream.stop()
                self.presentFailure(msg, title: "对话中断")
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

    /// 删除用户自己的场景（长按菜单触发）。
    func deleteScenario(_ sceneId: String) async {
        guard let token = auth.token else { statusMessage = "请先登录"; return }
        do {
            try await api.deleteScenario(sceneId: sceneId, token: token)
            todayScenarios.removeAll { $0.sceneId == sceneId }
            statusMessage = "场景已删除"
        } catch {
            presentFailure(error.localizedDescription, title: "删除失败")
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

    /// 通用场景已含完整对话：直接把预置场景转成摘要，走与「自己场景」完全一样的「选角色 → 对练」流程。
    func summary(for scene: PresetSceneItem) -> ScenarioSummary {
        let now = Date()
        return ScenarioSummary(
            sceneId: scene.sceneId,
            title: scene.title,
            summary: "",
            roles: scene.roles,
            lineCount: scene.lineCount,
            sourceStart: now,
            sourceEnd: now,
            createdAt: now,
            lastScore: scene.lastScore,
            lastPracticedAt: scene.lastPracticedAt,
            inProgress: scene.inProgress,
            resumeProgress: scene.resumeProgress
        )
    }

    /// 从「今日场景」卡片直接进入练习：拉取场景详情 → 选角色 → 开始对练
    /// 进入练习前：若指导/对话方式设为「每次询问」，先弹窗让用户选择（不可中途切换）。
    func startScenarioPractice(_ summary: ScenarioSummary, roleId: String, resume: Bool = false) async {
        guard auth.token != nil else {
            statusMessage = "请先登录"
            return
        }
        if guidancePreference == .ask || conversationPreference == .ask {
            pendingPractice = PendingPractice(summary: summary, roleId: roleId, resume: resume)
            return
        }
        conversationMode = resolvedConversationMode(conversationPreference)
        guidanceMode = guidancePreference == .final ? .final : .realtime
        await beginPractice(summary, roleId: roleId, resume: resume)
    }

    /// 「对话前询问」弹窗确认后：按所选模式开始，并按需记住偏好。
    func confirmPendingPractice(
        conversation: ConversationMode,
        guidance: GuidanceMode,
        rememberConversation: Bool,
        rememberGuidance: Bool
    ) async {
        guard let pending = pendingPractice else { return }
        conversationMode = (conversation == .voice && !isPremium) ? .immersive : conversation
        guidanceMode = guidance
        if rememberConversation {
            conversationPreference = conversationPreference(for: conversationMode)
        }
        if rememberGuidance {
            guidancePreference = guidance == .final ? .final : .realtime
        }
        savePracticePreferences()
        pendingPractice = nil
        await beginPractice(pending.summary, roleId: pending.roleId, resume: pending.resume)
    }

    func cancelPendingPractice() {
        pendingPractice = nil
    }

    private func beginPractice(_ summary: ScenarioSummary, roleId: String, resume: Bool = false) async {
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
            appendChat(.user, "练习：\(summary.title)（扮演\(roleName(roleId))\(resume ? "·继续上次" : "")）")
            if shouldUseVoiceLLM {
                await beginVoiceLLMPractice(resume: resume)
            } else {
                await startRoleplay(resume: resume)
            }
        } catch {
            isWorking = false
            presentFailure(error.localizedDescription, title: "无法开始练习")
        }
    }

    /// 高级会员沉浸式 + 实时语音大模型：在后端建立 roleplay 会话拿 session_id，再用 WebSocket 直接语音对话。
    /// 不走文本逐句对练（不设置 roleplay 状态），结束后由语音模型给出评分与分析。
    private func beginVoiceLLMPractice(resume: Bool = false) async {
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
                resume: resume,
                token: token
            )
            isWorking = false
            statusMessage = "实时语音对练已开始"
            showVoiceLLM = true
            await realtime.start(token: token, sessionId: state.sessionId, scenarioTitle: scene.title)
            await loadPracticeHistory()
        } catch {
            isWorking = false
            presentFailure(error.localizedDescription, title: "无法开始语音对练")
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
            let uploaded = await uploadPending(notifyFailure: true)
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
        presentFailure("今日免费采集时长已用完，已停止并提交生成场景；升级会员可不限时长。", title: "采集已停止")
        let uploaded = await uploadPending()
        if uploaded > 0 { await loadTodayScenarios() }
    }

    /// 开始采集前查询剩余额度：超额则拦截不采集；额度不足则提示但仍允许；记录额度用于采集中自动停止。
    private func startCaptureWithQuotaCheck() async {
        captureRemainingTokens = nil
        // 非会员每日采集时长限额（客户端本地强制；后端看不到采集过程）
        if isNonMember, nonmemberCaptureSecondsLimit > 0, capturedSecondsToday >= nonmemberCaptureSecondsLimit {
            presentFailure("今日免费采集时长已用完，升级会员可不限时长，或明天再来。", title: "无法开始采集")
            return
        }
        if let token = auth.token, let quota = try? await api.captureQuota(token: token) {
            if quota.canCapture == false {
                presentFailure(quota.message.isEmpty ? "当前额度不足，暂时无法采集。" : quota.message, title: "无法开始采集")
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
        presentFailure("本月 AI 额度已用完，已自动停止采集并提交生成场景；下月自动恢复。", title: "采集已停止")
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
        defaults.set(appearance.rawValue, forKey: DefaultsKey.appearance)
    }

    /// 是否高级会员：实时语音大模型对练是高级会员专属能力。
    var isPremium: Bool { auth.user?.effectiveTier == "premium" }

    /// 「对话方式」可选项：语音模型对话仅高级会员可选，非会员隐藏。
    var availableConversationPreferences: [ConversationPreference] {
        ConversationPreference.allCases.filter { $0 != .voice || isPremium }
    }

    /// 把「对话方式偏好」解析为本次会话实际模式：voice 仅高级会员生效，否则回退沉浸式。
    func resolvedConversationMode(_ pref: ConversationPreference) -> ConversationMode {
        switch pref {
        case .manual: return .manual
        case .voice: return isPremium ? .voice : .immersive
        case .immersive, .ask: return .immersive
        }
    }

    /// 把本次会话模式映射回可保存的偏好。
    func conversationPreference(for mode: ConversationMode) -> ConversationPreference {
        switch mode {
        case .manual: return .manual
        case .voice: return .voice
        case .immersive: return .immersive
        }
    }

    /// 本次是否走「实时语音大模型」：仅高级会员且本次对话方式为「语音模型对话」。
    var shouldUseVoiceLLM: Bool {
        isPremium && conversationMode == .voice
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
    /// notifyFailure=true（用户手动停止采集时）失败弹提示框；后台每小时自动重试时静默（内容已本地保留、会重试）。
    func uploadPending(notifyFailure: Bool = false) async -> Int {
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
            statusMessage = "正在上传…（\(pending.count) 句）"
            let response = try await api.uploadCaptureSegments(pending, token: token)
            transcripts.markUploaded(ids: pending.map(\.id))
            // 异步生成：上传成功即可，无需等待场景；生成完成后会出现在场景列表
            statusMessage = "上传成功，场景生成中，稍后在列表查看"
            return response.acceptedItems
        } catch {
            if notifyFailure {
                presentFailure("采集内容上传失败：\(error.localizedDescription)。内容已保留，稍后会自动重试。", title: "上传失败")
            } else {
                statusMessage = "上传失败：\(error.localizedDescription)"
            }
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

    func startRoleplay(resume: Bool = false) async {
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
        stream.stop()
        conversationExited = false
        isVoiceConversationActive = true
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
                resume: resume,
                token: token
            )
            scenario = state.scenario
            if usesStreamImmersive {
                // 沉浸式：WS 流驱动整段对话（识别/朗读/抢话都在流里）。先上屏开场状态再连流。
                roleplay = state
                selectedRoleID = state.selectedRole
                startImmersiveStream()
            } else {
                handleRoleplayState(state)
            }
            statusMessage = "语音对话已开始"
            await loadPracticeHistory()
        } catch {
            isVoiceConversationActive = false
            presentFailure(error.localizedDescription, title: "无法开始对话")
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
            if usesStreamImmersive {
                startImmersiveStream()
            } else {
                await listenForNextRoleplayTurn()
            }
        }
    }

    func pauseVoiceConversation() {
        isVoiceConversationActive = false
        cancelAnswerTimeout()
        practiceSpeech.stop(emit: false)
        voice.stop()
        stream.stop()
        statusMessage = "语音对话已暂停"
    }

    /// 用户主动退出对话界面：彻底停止并标记已退出，使「后台仍在处理的那一轮回包」回来后不再播报/续听。
    func exitConversation() {
        conversationExited = true
        pauseVoiceConversation()
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

        // 对练中所有发言都送 /roleplay/message 评分推进：
        // 即使用户说中文/「不知道怎么说」，后端也会判低分并在指导区给出应说的英文（correction），用户照着重说即可。
        // （此前命中关键词会改走 /ai/chat，提示只进了主聊天流、沉浸式界面看不到，且对话永不推进，表现为卡在第一句。）
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
            applyRoleplayTurnState(state)
            await loadPracticeHistory()
        } catch {
            // 系统/模型/额度异常中断了对话流程：停止本轮并弹失败提示框（保留会话，可重试或退出）
            isVoiceConversationActive = false
            practiceSpeech.stop(emit: false)
            presentFailure(error.localizedDescription, title: "对话中断")
        }
    }

    /// 后端语音回合：把录好的一句音频上传给后端识别+评分+发音纠正（方式1/2 共用）。
    func submitRoleplayAudio(_ fileURL: URL) async {
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard let token = auth.token else { statusMessage = "请先登录"; return }
        guard let roleplay else { statusMessage = "请先开始口语对练"; return }
        cancelAnswerTimeout()
        isWorking = true
        defer { isWorking = false }
        do {
            let state = try await api.roleplayMessageAudio(
                sessionId: roleplay.sessionId,
                guidanceMode: guidanceMode.rawValue,
                fileURL: fileURL,
                token: token
            )
            // 把后端识别到的英文当作「用户这句」上屏；附词级发音提示
            if let recognized = state.recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines), recognized.isEmpty == false {
                lastSpokenAnswer = recognized
                appendChat(.user, recognized)
                let missed = state.pronunciation.filter { $0.ok == false }.map(\.word)
                if missed.isEmpty == false {
                    appendChat(.system, "发音再注意：\(missed.joined(separator: "、"))")
                }
            }
            applyRoleplayTurnState(state)
            await loadPracticeHistory()
        } catch {
            isVoiceConversationActive = false
            practiceSpeech.stop(emit: false)
            presentFailure(error.localizedDescription, title: "对话中断")
        }
    }

    /// 一轮回包的统一处理（文字/语音共用）：反馈上屏 + 推进 + 朗读 AI 台词。
    private func applyRoleplayTurnState(_ state: RoleplayStateResponse) {
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
    }

    /// 供 VoicePromptPlayer 拉取后端 TTS 音频（主线程隔离，避免 actor 问题）。
    func fetchTTSAudio(_ text: String, cache: Bool = true) async -> Data? {
        guard let token = auth.token else { return nil }
        return try? await api.ttsSpeak(text: text, cache: cache, token: token)
    }

    /// 沉浸式是否走后端语音流（WebSocket：流式 + 抢话打断）。
    var usesStreamImmersive: Bool { conversationMode == .immersive }

    private func startImmersiveStream() {
        guard let token = auth.token, let sessionId = roleplay?.sessionId,
              let url = api.roleplayStreamURL(sessionId: sessionId, token: token) else { return }
        stream.start(streamURL: url, guidanceMode: guidanceMode.rawValue)
    }

    /// WebSocket 推来的整轮状态：直接刷新对练状态（字幕来自 roleplay.messages）。
    private func applyStreamState(_ data: Data) {
        guard let state = api.decodeRoleplayState(data) else { return }
        roleplay = state
        scenario = state.scenario
        selectedRoleID = state.selectedRole
        let missed = state.pronunciation.filter { $0.ok == false }.map(\.word)
        if let recognized = state.recognizedText, recognized.isEmpty == false, missed.isEmpty == false {
            practiceHintText = "发音再注意：\(missed.joined(separator: "、"))"
        }
        if state.completed {
            isVoiceConversationActive = false
            if let review = state.latestFeedback, review.isEmpty == false { statusMessage = review }
        } else if let fb = state.latestFeedback, fb.isEmpty == false {
            statusMessage = fb
        }
    }

    func loadTtsVoices() async {
        guard let token = auth.token else { return }
        if let v = try? await api.ttsVoices(token: token) {
            ttsVoices = v.voices
            ttsCurrentVoice = v.current
            ttsConfigured = v.configured
        }
    }

    func setTtsVoice(_ voice: String) async {
        guard let token = auth.token, voice.isEmpty == false else { return }
        if let v = try? await api.setTtsVoice(voice, token: token) {
            ttsVoices = v.voices
            ttsCurrentVoice = v.current
            statusMessage = "已设置 AI 音色：\(voice)"
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
                voice.speak(feedback, cache: false)   // 指导内容不入 Redis
            }
        } catch {
            presentFailure(error.localizedDescription, title: "评分获取失败")
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
    func submitSupportTicket(category: String, subject: String, body: String, images: [String] = []) async -> Bool {
        guard let token = auth.token else { statusMessage = "请先登录"; return false }
        do {
            _ = try await api.createSupportTicket(category: category, subject: subject, body: body, images: images, token: token)
            await loadMyTickets()
            statusMessage = "工单已提交，我们会尽快处理"
            return true
        } catch {
            presentFailure(error.localizedDescription, title: "工单提交失败")
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
            presentFailure(error.localizedDescription, title: "下单失败")
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
            presentFailure("文件过大，最大 300MB。", title: "无法上传")
            return
        }
        if let duration = try? await AVURLAsset(url: fileURL).load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 6 * 3600 {
                presentFailure("音频过长，最长 6 小时。", title: "无法上传")
                return
            }
        }

        isUploadingAudio = true
        defer { isUploadingAudio = false }

        do {
            // 断点续传上传（每个报文带文件 MD5，服务端按 MD5 路由到对应语音服务器）；
            // 服务端已有同文件则秒回成功。处理改为服务器端定时任务转写+生成场景，App 不再等待。
            let alreadyDone = try await api.uploadAudioResumable(fileURL: fileURL, token: token) { [weak self] fraction in
                Task { @MainActor in
                    self?.statusMessage = "上传中 \(Int(fraction * 100))%"
                }
            }
            statusMessage = alreadyDone
                ? "该录音此前已上传，无需重复上传"
                : "上传成功，场景生成中，稍后在列表查看"
        } catch {
            presentFailure(error.localizedDescription, title: "上传失败")
        }
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
            presentFailure(error.localizedDescription, title: "下单失败")
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
            presentFailure(error.localizedDescription, title: "支付确认失败")
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
        practiceHintText = nil   // 进入新一轮，清掉上一轮的超时英文提示
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

        // 用户已退出对话界面：状态已更新即可，绝不再播报 AI 语音或继续听（避免退到主界面后又冒出对话/语音）
        guard conversationExited == false else { return }

        guard newAIMessages.isEmpty == false else {
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
        guard roleplay?.completed == false, let next = roleplay?.nextLine else { return }
        guard practiceSpeech.isListening == false, voice.isSpeaking == false else { return }
        practiceSpeech.expectedPhrases = [next.english]   // 用目标台词偏置识别，提升转写准确度
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
        if let next = roleplay?.nextLine { practiceSpeech.expectedPhrases = [next.english] }
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
        // 在沉浸式指导区显示英文参考（之前 appendChat 只进主聊天流、沉浸式看不到）
        practiceHintText = "可以这样说：\(next.english)"
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
