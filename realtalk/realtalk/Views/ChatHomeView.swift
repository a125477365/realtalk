import SwiftUI

/// 常规对话主界面（新首页）：白底聊天流，自由聊天 / 自由场景 / 严格场景全在这一个界面。
/// - AI 卡片：朗读中动画、卡内「译」按钮显示中文、严格场景朗读中打码；
/// - 用户气泡：下方发音分/语速小行，点开进「详细指导」浮层（逐词标色/评分/语境润色）；
/// - 指导/提示卡直接插在字幕流里（不再有专门指导界面）；
/// - 顶部：重听 / 场景入口 + 当前用户；底部：采集 + 居中点击说话 + 键盘 / 私教。
struct ChatHomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var speech: SpeechCaptureManager
    @ObservedObject var freeStream: RoleplayStreamManager
    @ObservedObject var rpStream: RoleplayStreamManager

    @Environment(\.scenePhase) private var scenePhase
    @State private var showingAccount = false
    @State private var keyboardMode = false
    @State private var draft = ""
    @State private var guidanceItem: AppModel.HomeChatItem?
    @State private var showingAttach = false        // 底部「+」附加功能面板
    @State private var showingUpload = false        // 上传语音文件生成场景
    @FocusState private var draftFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                RTTheme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                    statusStrip
                    chatStream
                    if let scene = model.homeSceneName { sceneBanner(scene) }
                    inputBar
                }
            }
            .alert(item: $model.failureAlert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("我知道了")))
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
            // 底部「+」：上拉附加功能（采集/上传/选场景/自由聊/实时翻译）
            .sheet(isPresented: $showingAttach) {
                AttachmentSheet(showingUpload: $showingUpload)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingUpload) {
                UploadRecordingView()
            }
            // 私教通话（全屏，Claude 语音式界面）
            .fullScreenCover(isPresented: $model.showTutor) {
                TutorCallView(stream: freeStream)
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
            // 回到前台：连接掉了就兜底重连（此前只能重启 App 恢复）
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.reconnectIfNeeded() }
            }
            .task {
                await model.reloadAll()
                if model.homeConnected == false, model.showTutor == false {
                    model.startHomeChat()
                }
            }
        }
    }

    // MARK: 顶栏（左：账户；右：AI 语音开关 + 私教电话）

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { showingAccount = true } label: {
                HStack(spacing: 8) {
                    userAvatar
                    Text(displayName)
                        .font(.system(size: 14 * model.fontScale, weight: .semibold))
                        .foregroundStyle(RTTheme.textPrimary)
                        .lineLimit(1)
                }
                .padding(.leading, 4)
                .padding(.trailing, 10)
                .frame(height: 42)
                .background(RTTheme.surface, in: Capsule())
                .overlay(Capsule().stroke(RTTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("账户与会员设置")

            Spacer()

            // AI 语音自动播放开关：开＝彩色喇叭，关＝灰色斜杠喇叭（按下立即可见状态变化）
            Button { model.autoPlayAI.toggle() } label: {
                Image(systemName: model.autoPlayAI ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(model.autoPlayAI ? RTTheme.accent : RTTheme.textSecondary)
                    .frame(width: 42, height: 42)
                    .background(RTTheme.surface, in: Circle())
                    .overlay(Circle().stroke(model.autoPlayAI ? RTTheme.accent.opacity(0.45) : RTTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.autoPlayAI ? "关闭 AI 语音自动播放" : "开启 AI 语音自动播放")

            // 私教电话：进入全屏私教通话
            Button {
                model.tutorMode = "chat"
                model.showTutor = true
            } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(RTTheme.success)
                    .frame(width: 42, height: 42)
                    .background(RTTheme.surface, in: Circle())
                    .overlay(Circle().stroke(RTTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("私教通话")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var userAvatar: some View {
        if let raw = auth.user?.avatarUrl, let url = URL(string: raw) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    avatarFallback
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(Circle())
        } else {
            avatarFallback
        }
    }

    private var avatarFallback: some View {
        Circle()
            .fill(RTTheme.brandGradient)
            .frame(width: 34, height: 34)
            .overlay(
                Text(String(displayName.prefix(1)))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            )
    }

    private var displayName: String {
        let value = auth.user?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "微信用户" : value
    }

    @ViewBuilder
    private var statusStrip: some View {
        if speech.isRecording || model.showTutor || model.homeStatus.isEmpty == false {
            HStack(spacing: 6) {
                Circle()
                    .fill(speech.isRecording ? Color.red : (model.homeConnected ? RTTheme.success : RTTheme.textSecondary))
                    .frame(width: 6, height: 6)
                Text(statusLine)
                    .font(.system(size: 11 * model.fontScale, weight: .medium))
                    .foregroundStyle(speech.isRecording ? .red : RTTheme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(RTTheme.surface, in: Capsule())
            .padding(.bottom, 4)
        }
    }

    private var statusLine: String {
        if speech.isRecording { return "正在采集真实对话…" }
        if model.showTutor {
            if model.tutorMode == "translate" { return "实时翻译 · 共用字幕界面" }
            return model.tutorImmersive ? "私教 · 沉浸聆听中" : "私教 · 点击说话"
        }
        if model.homeStatus.isEmpty == false { return model.homeStatus }
        return model.homeConnected ? "已连接" : "正在连接"
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

    /// AI 大卡片：文本默认打码（点击文字显示）+ 波形重播/译 小按钮 + 中文翻译(卡内切换，缺失时按需翻译)。
    private func aiCard(_ item: AppModel.HomeChatItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.text)
                .font(.system(size: 16 * model.fontScale))
                .foregroundStyle(RTTheme.textPrimary)
                .blur(radius: item.masked ? 7 : 0)
                .animation(.easeOut(duration: 0.25), value: item.masked)
                .contentShape(Rectangle())
                .onTapGesture { model.toggleItemMasked(item.id) }
            if item.masked {
                Text("🎧 先听后看 · 点击文字显示")
                    .font(.system(size: 11 * model.fontScale))
                    .foregroundStyle(RTTheme.textSecondary)
            }
            HStack(spacing: 16) {
                // 波形＝重新播放这一句（与顶栏喇叭「自动播放开关」含义区分开）
                Button { model.speakText(item.text) } label: {
                    Image(systemName: "waveform")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(RTTheme.accent)
                }
                .accessibilityLabel("重新播放这一句")
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
            if item.showTranslation, item.masked == false {
                if item.translating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在翻译…")
                            .font(.system(size: 12 * model.fontScale))
                            .foregroundStyle(RTTheme.textSecondary)
                    }
                } else if item.translation.isEmpty == false {
                    Divider()
                    Text(item.translation)
                        .font(.system(size: 14 * model.fontScale))
                        .foregroundStyle(RTTheme.textSecondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(RTTheme.hairline, lineWidth: 1))
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
                // 发音指导入口常驻：没有词级数据（云端 ASR/实时通道）也能进「语境润色」
                Button { guidanceItem = item } label: {
                    HStack(spacing: 6) {
                        if item.words.isEmpty == false {
                            let score = pronunciationScore(item.words)
                            Text("发音 \(score)")
                                .foregroundStyle(score >= 80 ? RTTheme.success : (score >= 60 ? Color.orange : Color.red))
                        } else {
                            Text("发音指导").foregroundStyle(RTTheme.textSecondary)
                        }
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
            Label(name, systemImage: "film")
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

    // MARK: 输入区

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
                // 左：+（附加功能上拉面板）；采集中变成红色停止按钮，一眼可见正在采集
                Button {
                    if speech.isRecording {
                        Task { await model.toggleRecording() }
                    } else {
                        showingAttach = true
                    }
                } label: {
                    Image(systemName: speech.isRecording ? "stop.fill" : "plus")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(speech.isRecording ? .white : RTTheme.textPrimary)
                        .frame(width: 48, height: 48)
                        .background(speech.isRecording ? Color.red : RTTheme.surface, in: Circle())
                        .overlay(Circle().stroke(speech.isRecording ? Color.clear : RTTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(speech.isRecording ? "停止采集并生成场景" : "更多功能")

                talkButton

                Button {
                    keyboardMode = true
                    draftFocused = true
                } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: 18))
                        .foregroundStyle(RTTheme.textPrimary)
                        .frame(width: 48, height: 48)
                        .background(RTTheme.surface, in: Circle())
                        .overlay(Circle().stroke(RTTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("键盘输入")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private var recordingNow: Bool {
        model.homeSceneStrict ? rpStream.manualRecording : freeStream.manualRecording
    }

    /// 说话按钮：描边样式（与主界面背景区分即可，不再用品牌渐变大色块）；录音中红色实心。
    private var talkButton: some View {
        Button {
            model.toggleHomeTalk()
        } label: {
            HStack(spacing: 10) {
                if model.homeWorking {
                    ProgressView().tint(RTTheme.textSecondary)
                    Text("请稍候…").foregroundStyle(RTTheme.textSecondary)
                } else {
                    Image(systemName: recordingNow ? "stop.fill" : "mic.fill")
                        .foregroundStyle(recordingNow ? .white : RTTheme.accent)
                    Text(recordingNow ? "说完了，发送" : "点击说话")
                        .foregroundStyle(recordingNow ? .white : RTTheme.textPrimary)
                }
            }
            .font(.system(size: 16 * model.fontScale, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 50)
            .frame(height: 50)
            .background(recordingNow ? AnyShapeStyle(Color.red) : AnyShapeStyle(RTTheme.surface),
                        in: RoundedRectangle(cornerRadius: 25))
            .overlay(
                RoundedRectangle(cornerRadius: 25)
                    .stroke(recordingNow ? Color.clear : RTTheme.hairline, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.homeWorking)
        .accessibilityHint("开始或结束本轮录音")
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        model.sendHomeText(text)
    }
}

/// 底部「+」上拉附加功能面板（参考 Claude App「Add to Chat」样式）：
/// 实时录音生成场景 / 上传语音文件 / 选择场景练习（严格或自由）/ 自由聊天 / 实时翻译。
struct AttachmentSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var speech: SpeechCaptureManager
    @Environment(\.dismiss) private var dismiss
    @Binding var showingUpload: Bool

    var body: some View {
        ZStack {
            RTTheme.background.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("添加到对话")
                    .font(.headline)
                    .foregroundStyle(RTTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 18)

                VStack(spacing: 0) {
                    attachRow(
                        icon: speech.isRecording ? "stop.circle.fill" : "waveform.badge.mic",
                        tint: speech.isRecording ? .red : RTTheme.accent,
                        title: speech.isRecording ? "停止采集并生成场景" : "实时录音生成场景",
                        subtitle: "采集你身边的真实对话，自动还原成英语练习场景"
                    ) {
                        dismiss()
                        Task { await model.toggleRecording() }
                    }
                    divider
                    attachRow(
                        icon: "square.and.arrow.up.on.square",
                        tint: RTTheme.accent,
                        title: "上传语音文件生成场景",
                        subtitle: "上传手机或录音笔里的录音（高级会员）"
                    ) {
                        dismiss()
                        showingUpload = true
                    }
                    divider
                    attachRow(
                        icon: "film",
                        tint: RTTheme.accent,
                        title: "选择场景练习",
                        subtitle: "选好场景后可选：严格按剧本对话 / 围绕场景自由发挥"
                    ) {
                        dismiss()
                        model.showScenePicker = true
                    }
                    divider
                    attachRow(
                        icon: "bubble.left.and.bubble.right",
                        tint: RTTheme.success,
                        title: "自由对话",
                        subtitle: model.homeSceneName == nil ? "不带场景，和老师随便聊" : "退出当前场景，回到自由闲聊"
                    ) {
                        dismiss()
                        if model.homeSceneName != nil {
                            model.exitHomeScene()
                        } else if model.homeConnected == false {
                            model.startHomeChat()
                        }
                    }
                    divider
                    attachRow(
                        icon: "globe",
                        tint: RTTheme.accent,
                        title: "实时翻译",
                        subtitle: "说中文出英文、说英文出中文，逐句同传"
                    ) {
                        dismiss()
                        model.tutorMode = "translate"
                        model.showTutor = true
                    }
                }
                .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(RTTheme.hairline, lineWidth: 1))

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
        }
    }

    private var divider: some View {
        Divider().overlay(RTTheme.hairline).padding(.leading, 56)
    }

    private func attachRow(icon: String, tint: Color, title: String, subtitle: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16 * model.fontScale, weight: .medium))
                        .foregroundStyle(RTTheme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12 * model.fontScale))
                        .foregroundStyle(RTTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
