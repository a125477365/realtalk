import Combine
import Foundation

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

    let transcripts: TranscriptStore
    let speech: SpeechCaptureManager
    let api: APIClient
    let auth: AuthStore
    let subscription: SubscriptionManager
    let practiceSpeech: SpeechPracticeManager
    let voice: VoicePromptPlayer

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
    @Published var audioJobs: [AudioJob] = []
    @Published var isUploadingAudio = false
    @Published var todayScenarios: [ScenarioSummary] = []
    @Published var isLoadingScenarios = false
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
    @Published var autoCaptureEnabled = false
    @Published var autoCaptureStart = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @Published var autoCaptureEnd = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
    @Published var fontScale: Double = 1.0
    @Published var lastSpokenAnswer = ""
    @Published var trainingAnswer = ""
    @Published var isWorking = false
    @Published var statusMessage = ""

    private var captureScheduleLoop: Task<Void, Never>?
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
        autoCaptureEnabled = defaults.bool(forKey: DefaultsKey.autoCaptureEnabled)
        autoCaptureStart = defaults.object(forKey: DefaultsKey.autoCaptureStart) as? Date ?? autoCaptureStart
        autoCaptureEnd = defaults.object(forKey: DefaultsKey.autoCaptureEnd) as? Date ?? autoCaptureEnd
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
            await startRoleplay()
        } catch {
            isWorking = false
            statusMessage = error.localizedDescription
        }
    }

    func toggleRecording() async {
        if speech.isRecording {
            speech.stop(savePartial: true)
            statusMessage = "已停止采集，正在发送给后台并生成场景…"
            try? await Task.sleep(nanoseconds: 400_000_000)
            let uploaded = await uploadPending()
            if uploaded > 0 {
                await loadTodayScenarios()
            }
        } else {
            await speech.start()
            statusMessage = "正在采集真实对话"
        }
    }

    func saveCaptureSchedule() {
        defaults.set(autoCaptureEnabled, forKey: DefaultsKey.autoCaptureEnabled)
        defaults.set(autoCaptureStart, forKey: DefaultsKey.autoCaptureStart)
        defaults.set(autoCaptureEnd, forKey: DefaultsKey.autoCaptureEnd)
        Task { await evaluateAutomaticCaptureWindow() }
    }

    func savePracticePreferences() {
        defaults.set(fontScale, forKey: DefaultsKey.fontScale)
        defaults.set(guidancePreference.rawValue, forKey: DefaultsKey.guidancePreference)
        defaults.set(conversationPreference.rawValue, forKey: DefaultsKey.conversationPreference)
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
        isUploadingAudio = true
        defer { isUploadingAudio = false }
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
        voice.speak("Take your time. Try saying: \(next.english)") { [weak self] in
            Task { @MainActor in
                await self?.listenForNextRoleplayTurn()
            }
        }
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
        guard roleplay?.completed == false, let next = roleplay?.nextLine else { return }
        voice.speak("Try saying: \(next.english)") { [weak self] in
            Task { @MainActor in
                await self?.listenForNextRoleplayTurn()
            }
        }
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
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    private func evaluateAutomaticCaptureWindow() async {
        guard autoCaptureEnabled else { return }
        guard isVoiceConversationActive == false else { return }

        if isNowInsideAutomaticCaptureWindow() {
            if speech.isRecording == false {
                await speech.start()
                statusMessage = "已按默认时间开始采集"
            }
        } else if speech.isRecording {
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
        let start = minutesSinceStartOfDay(autoCaptureStart, calendar: calendar)
        let end = minutesSinceStartOfDay(autoCaptureEnd, calendar: calendar)

        if start == end {
            return false
        }
        if start < end {
            return current >= start && current < end
        }
        return current >= start || current < end
    }

    private func minutesSinceStartOfDay(_ date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}
