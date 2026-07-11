import SwiftUI

/// 常规对话主界面（新首页）：白底聊天流，自由聊天 / 自由场景 / 严格场景全在这一个界面。
/// - AI 卡片：朗读中动画、卡内「译」按钮显示中文、严格场景朗读中打码；
/// - 用户气泡：下方发音分/语速小行，点开进「详细指导」浮层（逐词标色/评分/语境润色）；
/// - 指导/提示卡直接插在字幕流里（不再有专门指导界面）；
/// - 底部：选场景/实时翻译/采集 工具条 + 点击说话 + 键盘输入 + 电话（私教）。
struct ChatHomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var speech: SpeechCaptureManager
    @ObservedObject var freeStream: RoleplayStreamManager
    @ObservedObject var rpStream: RoleplayStreamManager

    @State private var showingAccount = false
    @State private var keyboardMode = false
    @State private var draft = ""
    @State private var guidanceItem: AppModel.HomeChatItem?
    @FocusState private var draftFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                RTTheme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                    chatStream
                    if let scene = model.homeSceneName { sceneBanner(scene) }
                    toolStrip
                    inputBar
                }
            }
            .alert(item: $model.failureAlert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("我知道了")))
            }
            .fullScreenCover(isPresented: $model.showTutor) {
                TutorCallView(stream: model.freeStream)
            }
            .sheet(isPresented: $model.showScenePicker) {
                ScenarioPickerView()
            }
            .sheet(item: $guidanceItem) { item in
                GuidanceDetailSheet(item: item)
            }
            .sheet(isPresented: $showingAccount) {
                AccountPanelView()
                    .presentationDetents([.large])
            }
            // 学习提醒「私教来电」
            .fullScreenCover(isPresented: Binding(
                get: { model.incomingReminder != nil },
                set: { if $0 == false { model.incomingReminder = nil } }
            )) {
                if let scenario = model.incomingReminder {
                    ReminderCallView(scenario: scenario)
                }
            }
            // 来电中选「现在练习」→ 打开场景选择流程（选角色+严格/自由）
            .onChange(of: model.reminderPracticeScene) { _, scene in
                if scene != nil { model.showScenePicker = true }
            }
            // 严格场景：AI 朗读结束 → 揭示打码台词
            .onChange(of: rpStream.isAISpeaking) { _, speaking in
                if speaking == false { model.revealMasked() }
            }
            .onChange(of: freeStream.isAISpeaking) { _, speaking in
                if speaking == false { model.revealMasked() }
            }
            .task {
                await model.reloadAll()
                if model.homeConnected == false, model.showTutor == false {
                    model.startHomeChat()
                }
            }
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(RTTheme.brandGradient)
                .frame(width: 34, height: 34)
                .overlay(Text("R").font(.system(size: 17, weight: .bold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 1) {
                Text("AI 老师")
                    .font(.system(size: 17 * model.fontScale, weight: .semibold))
                    .foregroundStyle(RTTheme.textPrimary)
                Text(statusLine)
                    .font(.system(size: 11 * model.fontScale))
                    .foregroundStyle(speech.isRecording ? .red : RTTheme.textSecondary)
            }
            Spacer()
            Button { showingAccount = true } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(RTTheme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusLine: String {
        if speech.isRecording { return "正在采集真实对话…" }
        if model.homeStatus.isEmpty == false { return model.homeStatus }
        return auth.user?.tierName ?? "用真实生活练英语"
    }

    // MARK: 字幕流

    private var chatStream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.homeItems.isEmpty {
                        Text(model.homeStatus.isEmpty ? "直接开口说英语，或点下方按钮选场景练习" : model.homeStatus)
                            .font(.system(size: 13 * model.fontScale))
                            .foregroundStyle(RTTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 80)
                    }
                    ForEach(model.homeItems) { item in
                        itemRow(item)
                            .id(item.id)
                    }
                    Color.clear.frame(height: 6).id("homeBottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onChange(of: model.homeItems.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("homeBottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: AppModel.HomeChatItem) -> some View {
        switch item.kind {
        case .ai: aiCard(item)
        case .user: userBubble(item)
        case .guidance: guidanceCard(item)
        case .hint: hintCard(item)
        }
    }

    /// AI 大卡片：文本(打码时模糊) + 朗读/译 小按钮 + 中文翻译(卡内切换)。
    private func aiCard(_ item: AppModel.HomeChatItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.text)
                .font(.system(size: 16 * model.fontScale))
                .foregroundStyle(RTTheme.textPrimary)
                .blur(radius: item.masked ? 7 : 0)
                .animation(.easeOut(duration: 0.25), value: item.masked)
            if item.masked {
                Text("先听老师说完，再看文字 🎧")
                    .font(.system(size: 11 * model.fontScale))
                    .foregroundStyle(RTTheme.textSecondary)
            }
            HStack(spacing: 16) {
                Button { model.speakText(item.text) } label: {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 15))
                        .foregroundStyle(RTTheme.accent)
                }
                Button { model.toggleItemTranslation(item.id) } label: {
                    Text("译")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.showTranslation ? .white : RTTheme.accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(item.showTranslation ? AnyShapeStyle(RTTheme.accent) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(RTTheme.accent, lineWidth: 1))
                }
                Spacer()
            }
            if item.showTranslation, item.translation.isEmpty == false, item.masked == false {
                Divider()
                Text(item.translation)
                    .font(.system(size: 14 * model.fontScale))
                    .foregroundStyle(RTTheme.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    /// 用户气泡 + 发音/语速指导行（点开详细指导浮层）。
    private func userBubble(_ item: AppModel.HomeChatItem) -> some View {
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .trailing, spacing: 5) {
                Text(item.text)
                    .font(.system(size: 16 * model.fontScale))
                    .foregroundStyle(RTTheme.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RTTheme.userBubble, in: RoundedRectangle(cornerRadius: 16))
                if item.words.isEmpty == false {
                    Button { guidanceItem = item } label: {
                        HStack(spacing: 6) {
                            let score = pronunciationScore(item.words)
                            Text("发音 \(score)")
                                .foregroundStyle(score >= 80 ? RTTheme.success : (score >= 60 ? Color.orange : Color.red))
                            if item.wpm > 0 {
                                Text("语速 \(item.wpm)词/分").foregroundStyle(RTTheme.textSecondary)
                            }
                            Text("详情").foregroundStyle(RTTheme.accent)
                            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(RTTheme.accent)
                        }
                        .font(.system(size: 12 * model.fontScale, weight: .medium))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 指导对话卡（评语/纠正/完成总结）——插在字幕流里，不再有专门指导界面。
    private func guidanceCard(_ item: AppModel.HomeChatItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill").font(.system(size: 12)).foregroundStyle(.orange)
                Text("老师指导").font(.system(size: 12 * model.fontScale, weight: .semibold)).foregroundStyle(.orange)
            }
            Text(item.text)
                .font(.system(size: 14 * model.fontScale))
                .foregroundStyle(RTTheme.textPrimary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }

    /// 中文提示卡（严格场景：下一句该说什么）。
    private func hintCard(_ item: AppModel.HomeChatItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.text)
                .font(.system(size: 14 * model.fontScale, weight: .medium))
                .foregroundStyle(RTTheme.accent)
            if item.translation.isEmpty == false {
                Text(item.translation)
                    .font(.system(size: 12 * model.fontScale))
                    .foregroundStyle(RTTheme.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RTTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func pronunciationScore(_ words: [RoleplayStreamManager.WordScore]) -> Int {
        guard words.isEmpty == false else { return 0 }
        let avg = words.map(\.probability).reduce(0, +) / Double(words.count)
        return Int((avg * 100).rounded())
    }

    // MARK: 场景条（名字 + 严格/自由 + 退出）

    private func sceneBanner(_ name: String) -> some View {
        HStack(spacing: 8) {
            Text("🎬 \(name)")
                .font(.system(size: 14 * model.fontScale, weight: .semibold))
                .foregroundStyle(RTTheme.textPrimary)
            Text(model.homeSceneStrict ? "严格按剧本" : "自由发挥")
                .font(.system(size: 11 * model.fontScale))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(model.homeSceneStrict ? Color.orange : RTTheme.success, in: Capsule())
            Spacer()
            Button { model.exitHomeScene() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(RTTheme.textSecondary)
                    .padding(8)
                    .background(RTTheme.hairline, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(RTTheme.surface)
    }

    // MARK: 工具条 + 输入区

    private var toolStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                toolChip("选场景", icon: "film") { model.showScenePicker = true }
                toolChip("实时翻译", icon: "globe") {
                    model.tutorMode = "translate"
                    model.showTutor = true
                }
                toolChip(speech.isRecording ? "停止采集并生成场景" : "采集日常对话",
                         icon: speech.isRecording ? "stop.circle" : "waveform.badge.plus",
                         tint: speech.isRecording ? .red : nil) {
                    Task { await model.toggleRecording() }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 6)
    }

    private func toolChip(_ label: String, icon: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12))
                Text(label).font(.system(size: 13 * model.fontScale, weight: .medium))
            }
            .foregroundStyle(tint ?? RTTheme.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RTTheme.surface, in: Capsule())
            .overlay(Capsule().stroke(RTTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            if keyboardMode {
                TextField("输入英文或中文…", text: $draft, axis: .vertical)
                    .focused($draftFocused)
                    .lineLimit(1...4)
                    .font(.system(size: 15 * model.fontScale))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                    .onSubmit(sendDraft)
                Button(action: sendDraft) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(RTTheme.accent, in: Circle())
                }
                Button { keyboardMode = false } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 18))
                        .foregroundStyle(RTTheme.textSecondary)
                        .frame(width: 40, height: 44)
                }
            } else {
                talkButton
                Button {
                    keyboardMode = true
                    draftFocused = true
                } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: 19))
                        .foregroundStyle(RTTheme.textPrimary)
                        .frame(width: 44, height: 50)
                        .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                }
                Button {
                    model.tutorMode = "chat"
                    model.showTutor = true
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 50, height: 50)
                        .background(RTTheme.success, in: Circle())
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var recordingNow: Bool {
        model.homeSceneStrict ? rpStream.manualRecording : freeStream.manualRecording
    }

    private var talkButton: some View {
        Button { model.toggleHomeTalk() } label: {
            HStack(spacing: 10) {
                if model.homeWorking {
                    ProgressView().tint(.white)
                    Text("请稍候…")
                } else {
                    Image(systemName: recordingNow ? "stop.fill" : "mic.fill")
                    Text(recordingNow ? "说完了，发送" : "点击说话")
                }
            }
            .font(.system(size: 16 * model.fontScale, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(recordingNow ? AnyShapeStyle(Color.red) : AnyShapeStyle(RTTheme.brandGradient),
                        in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(model.homeWorking)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        model.sendHomeText(text)
    }
}
