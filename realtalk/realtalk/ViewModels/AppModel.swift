import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
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
            text: "今天想还原哪段真实对话？比如：我想练习今天中午订餐时与服务员的对话流程，你是服务员，我还是我。"
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
    @Published var autoCaptureEnabled = false
    @Published var autoCaptureStart = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @Published var autoCaptureEnd = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
    @Published var lastSpokenAnswer = ""
    @Published var trainingAnswer = ""
    @Published var isWorking = false
    @Published var statusMessage = ""

    private var uploadLoop: Task<Void, Never>?
    private var captureScheduleLoop: Task<Void, Never>?
    private var answerTimeoutTask: Task<Void, Never>?
    private var spokenMessageIDs: Set<String> = []
    private var chattedRoleplayMessageIDs: Set<String> = []
    private let defaults = UserDefaults.standard
    /// 轮到用户说话后，超过该秒数仍未开口则由 AI 主动给提示（要求 12）
    private let answerTimeoutSeconds: UInt64 = 20

    private enum DefaultsKey {
        static let autoCaptureEnabled = "realtalk.autoCaptureEnabled"
        static let autoCaptureStart = "realtalk.autoCaptureStart"
        static let autoCaptureEnd = "realtalk.autoCaptureEnd"
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

        speech.onSegment = { [weak self] text, date in
            self?.transcripts.addSegment(text: text, at: date)
        }
        practiceSpeech.onUtterance = { [weak self] text in
            Task { @MainActor in
                await self?.submitRoleplayUtterance(text)
            }
        }
    }

    deinit {
        uploadLoop?.cancel()
        captureScheduleLoop?.cancel()
        answerTimeoutTask?.cancel()
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
        startUploadLoop()
        startCaptureScheduleLoop()
        await evaluateAutomaticCaptureWindow()
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
                appendChat(.assistant, "我已根据你今天的真实对话生成了新的英语场景，点上方卡片就能开练。")
            }
        } catch {
            if statusMessage.isEmpty {
                statusMessage = error.localizedDescription
            }
        }
    }

    /// 从「今日场景」卡片直接进入练习：拉取场景详情 → 选角色 → 开始对练
    func startScenarioPractice(_ summary: ScenarioSummary, roleId: String) async {
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
        } else {
            await speech.start()
        }
    }

    func saveCaptureSchedule() {
        defaults.set(autoCaptureEnabled, forKey: DefaultsKey.autoCaptureEnabled)
        defaults.set(autoCaptureStart, forKey: DefaultsKey.autoCaptureStart)
        defaults.set(autoCaptureEnd, forKey: DefaultsKey.autoCaptureEnd)
        Task { await evaluateAutomaticCaptureWindow() }
    }

    func sendMainChatMessage(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.isEmpty == false else { return }

        appendChat(.user, prompt)

        if prompt.contains("开始录音") || prompt.contains("开始采集") {
            if speech.isRecording == false {
                await speech.start()
            }
            appendChat(.assistant, "我已开始采集真实世界对话。之后你可以说“练习今天中午订餐”，我会只用已转写的真实内容来还原场景。")
            return
        }

        if prompt.contains("停止录音") || prompt.contains("停止采集") {
            speech.stop(savePartial: true)
            await uploadPending()
            appendChat(.assistant, "已停止采集，并把待同步的文字转写上传到后台。")
            await loadTodayScenarios()
            return
        }

        if prompt.contains("显示台词") || prompt.contains("显示字幕") {
            showDialogueContent = true
            appendChat(.assistant, "已显示台词。练习时会看到中文提示和英文参考。")
            return
        }

        if prompt.contains("隐藏台词") || prompt.contains("隐藏字幕") {
            showDialogueContent = false
            appendChat(.assistant, "已隐藏完整台词；轮到你说时仍会保留中文提示。")
            return
        }

        if prompt.contains("换角色") || prompt.contains("对换角色") {
            await switchRoleAndRestart()
            return
        }

        if isPracticeHelpRequest(prompt) {
            if roleplay?.completed == false {
                await providePracticeHint(for: prompt)
            } else {
                await askBackendAI(prompt, fallback: { [weak self] in
                    self?.appendCurrentHint()
                })
            }
            return
        }

        if prompt.contains("结束") || prompt.contains("总结") || prompt.contains("纠正") {
            await askBackendAI(prompt, fallback: { [weak self] in
                self?.appendPracticeSummary()
            })
            return
        }

        if prompt.contains("练习") || prompt.contains("模拟") || prompt.contains("重现") || prompt.contains("还原") {
            configureConversationRange(from: prompt)
            await generateScenario()
            if scenario != nil {
                selectedRoleID = scenario?.roles.first(where: { $0.id == "self" && $0.isUserCandidate })?.id
                    ?? scenario?.roles.first(where: { $0.isUserCandidate })?.id
                    ?? ""
                appendChat(.assistant, "我会按你选的真实时间段还原场景。我来扮演对方，你说自己的英文；如果卡住，直接说“提示”。")
                await startRoleplay()
            }
            return
        }

        if roleplay?.completed == false, roleplay?.nextLine != nil {
            await submitRoleplayUtterance(prompt)
            return
        }

        await askBackendAI(
            prompt,
            fallback: { [weak self] in
                self?.appendChat(.assistant, "可以直接告诉我你想练哪段真实对话，也可以说“开始录音”先采集素材。")
            }
        )
    }

    func uploadPending() async {
        guard let token = auth.token else {
            statusMessage = "请先登录后同步"
            return
        }

        let pending = transcripts.pendingUpload
        guard pending.isEmpty == false else {
            statusMessage = "没有待同步内容"
            return
        }

        do {
            let response = try await api.uploadTranscripts(pending, token: token)
            transcripts.markUploaded(ids: pending.map(\.id))
            statusMessage = "已同步 \(response.uploaded) 条，对话云端保留 \(response.retentionDays) 天"
        } catch {
            statusMessage = error.localizedDescription
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
                // 引导放进聊天流，主界面随处可见（statusMessage 只在账户面板展示）
                chatMessages.append(ChatMessage(
                    sender: .assistant,
                    text: "先选一个练习场景：点上方「今日场景」卡片，或点右上角按钮采集今天的真实对话。"
                ))
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
                token: token
            )
            let feedback = state.latestFeedback?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let feedback, feedback.isEmpty == false {
                statusMessage = feedback
                appendChat(.assistant, feedback)
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

    func subscribe(planId: String) async {
        guard let token = auth.token else {
            statusMessage = "请先登录"
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let account = try await api.subscribe(planId: planId, token: token)
            billingAccount = account
            auth.applyBillingUser(account.user)
            statusMessage = "开通成功，当前为\(account.user.tierName)"
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
            _ = try await api.uploadAudio(fileURL: fileURL, token: token)
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
            statusMessage = "充值已入账"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func replayLastAI() {
        guard let message = roleplay?.messages.last(where: { $0.speaker == "ai" }) else { return }
        voice.speak(message.content)
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
        guard continuousVoiceMode else { return }
        guard roleplay?.completed == false, roleplay?.nextLine != nil else { return }
        guard practiceSpeech.isListening == false, voice.isSpeaking == false else { return }
        await practiceSpeech.start()
        scheduleAnswerTimeout()
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
        appendChat(.assistant, "别紧张，我来帮你。\n中文提示：\(next.sourceText)\n可以这样说：\(next.english)")
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

    private func startUploadLoop() {
        guard uploadLoop == nil else { return }
        uploadLoop = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
                await self?.uploadPending()
            }
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
            await uploadPending()
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
