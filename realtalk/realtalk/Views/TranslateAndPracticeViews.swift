import SwiftUI

// MARK: - 实时翻译（主界面右上角「A中」进入，全屏）

/// 实时翻译：说中文→听到英文，说英文→听到中文（边说边出，服务端自动分句）。
/// 退出时把本次全部原文交给后台智能生成英文场景（可能切分成多个场景），回到主界面即可练。
struct TranslateCallView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var stream: RoleplayStreamManager

    @State private var showVoicePanel = false

    private var liveLevel: Double { stream.isAISpeaking ? stream.aiAudioLevel : stream.audioLevel }

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.08, blue: 0.10).ignoresSafeArea()
            RadialGradient(
                colors: [Color(red: 0.25, green: 0.47, blue: 0.85).opacity(0.28 + 0.5 * liveLevel),
                         Color(red: 0.16, green: 0.30, blue: 0.62).opacity(0.10 + 0.25 * liveLevel), .clear],
                center: UnitPoint(x: 0.5, y: 1.12), startRadius: 10, endRadius: 330 + 260 * liveLevel
            )
            .ignoresSafeArea().allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: liveLevel)

            VStack(spacing: 0) {
                header
                // 状态行紧贴顶栏，与下方字幕拉开距离（否则挤在一起显乱）
                statusLine.padding(.top, 6).padding(.bottom, 16)
                // 字幕区占满中间剩余空间（此前固定高度 + Spacer 会把新句挤到可视区之外，
                // 表现为「界面只显示上边一部分」）；内部自动滚到最新一句。
                subtitles.frame(maxHeight: .infinity).clipped()   // 裁剪：滚动内容不许盖到状态行上
                // 「+」内联面板：与手动触发式同款（深色配色），在麦克风上方展开
                if showVoicePanel {
                    InlineVoiceSpeedPanel(dark: true).transition(.move(edge: .bottom))
                }
                // 麦克风一排：左「+」(音色/语速) + 中间大麦克风；右侧等宽占位保证麦克风居中。
                // 整行高度固定(140)，不随音量变化，字幕才不会被顶。
                HStack(spacing: 22) {
                    voiceButton
                    micIndicator
                    Color.clear.frame(width: 48, height: 48)
                }
                .frame(height: 140)
                .padding(.bottom, 18)
                Text("翻译内容会自动整理成英文场景，可回主界面练习")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    .padding(.bottom, 10)
            }
        }
        .onAppear { model.startTutor() }
    }

    /// 音色/语速入口：与其它对话界面统一用「+」，点击内联展开（与手动触发式同款面板）。
    private var voiceButton: some View {
        DarkPlusButton(rotated: showVoicePanel) {
            withAnimation(.easeOut(duration: 0.2)) { showVoicePanel.toggle() }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 5) {
                Circle().fill(model.homeConnected ? RTTheme.success : .red).frame(width: 7, height: 7)
                Text("实时翻译").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.white.opacity(0.10), in: Capsule())
            Spacer()
            Button { model.exitTranslate() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    .padding(10).background(.white.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("结束翻译")
        }
        .padding(.horizontal, 18).padding(.top, 10)
    }

    private var statusLine: some View {
        Text(model.homeConnected == false ? "连接中…"
             : (model.homeStatus.isEmpty ? "直接开口说话，中英自动互译" : model.homeStatus))
            .font(.system(size: 15 * model.fontScale, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity)
    }

    /// 成对字幕：原文 + 蓝色译文；始终自动滚到最新一句。
    private var translateItems: [AppModel.HomeChatItem] {
        model.homeItems.filter { $0.kind == .translate }
    }

    private var subtitles: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                ForEach(translateItems) { item in
                    let cn = isChinese(item.text)
                    VStack(alignment: cn ? .trailing : .leading, spacing: 5) {
                        Text(item.text)
                            .font(.system(size: 17 * model.fontScale, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: cn ? .trailing : .leading)
                        if item.translating || item.translation.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini).tint(.white)
                                Text("正在翻译…").font(.system(size: 13 * model.fontScale))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .frame(maxWidth: .infinity, alignment: cn ? .trailing : .leading)
                        } else {
                            HStack(spacing: 10) {
                                if cn == false { replay(item.translation) }
                                Text(item.translation)
                                    .font(.system(size: 16 * model.fontScale, weight: .semibold))
                                    .foregroundStyle(Color(red: 0.36, green: 0.66, blue: 1.0))
                                if cn { replay(item.translation) }
                            }
                            .frame(maxWidth: .infinity, alignment: cn ? .trailing : .leading)
                        }
                    }
                    .id(item.id)
                }
                Color.clear.frame(height: 1).id("translate-bottom")
            }
            .padding(.horizontal, 24).padding(.top, 16)
            }
            // 新句到达就滚到底，保证永远看得到最新一句（此前新句在可视区外）
            .onChange(of: translateItems.count) { _, _ in
                withAnimation { proxy.scrollTo("translate-bottom", anchor: .bottom) }
            }
            .onChange(of: translateItems.last?.translation) { _, _ in
                withAnimation { proxy.scrollTo("translate-bottom", anchor: .bottom) }
            }
        }
    }

    private func replay(_ text: String) -> some View {
        Button { model.speakText(text) } label: {
            Image(systemName: "waveform").font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
        .accessibilityLabel("重播译文")
    }

    /// 左右对齐只看【第一个有效字】：中文开头→靠右（用户说中文），否则靠左。
    /// 一句话中英混说时不再按字数比例摇摆，显示位置稳定。
    private func isChinese(_ s: String) -> Bool {
        for ch in s {
            for u in ch.unicodeScalars {
                if u.value >= 0x4E00 && u.value <= 0x9FFF { return true }          // 汉字
                if ("a"..."z").contains(Character(u)) || ("A"..."Z").contains(Character(u)) { return false }
            }
        }
        return false   // 全是标点/数字：按英文侧
    }

    @ViewBuilder
    private var micIndicator: some View {
        if model.homeConnected == false {
            Button { model.reconnectTutor() } label: {
                HStack(spacing: 8) { Image(systemName: "arrow.clockwise"); Text("重连") }
                    .font(.system(size: 17 * model.fontScale, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 40).padding(.vertical, 15)
                    .background(.white, in: Capsule())
            }
        } else {
            // 翻译是连续上行（服务端自动分句）：麦克风只作开关
            Button { stream.togglePause() } label: {
                PulsingMic(level: liveLevel,
                           symbol: stream.isPaused ? "mic.slash.fill" : "mic.fill",
                           ringColor: RTTheme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(stream.isPaused ? "开启麦克风" : "关闭麦克风")
        }
    }
}

// MARK: - 语音界面公用小组件

/// 会呼吸的圆形麦克风。关键：外层【固定 140×140】占位，脉冲只在内部涨落，
/// 绝不改变自身尺寸——否则整行高度随音量变化，会把上方字幕一起顶得上下抖动。
struct PulsingMic: View {
    let level: Double
    let symbol: String
    var ringColor: Color = RTTheme.accent

    var body: some View {
        ZStack {
            Circle()
                .stroke(ringColor.opacity(0.35 + 0.4 * level), lineWidth: 2)
                .frame(width: 96 + 34 * level, height: 96 + 34 * level)
            Circle().fill(.white.opacity(0.10)).frame(width: 84, height: 84)
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium)).foregroundStyle(.white)
                .scaleEffect(1 + 0.18 * level)
        }
        .animation(.easeOut(duration: 0.1), value: level)
        .frame(width: 140, height: 140)   // 固定占位：脉冲不外扩、不影响布局
    }
}

/// 深色语音界面的「+」按钮（音色/语速入口）：固定大小，不随音量跳动；
/// 面板展开时旋转 45° 变「×」（与手动触发式的 +/× 切换一致）。
struct DarkPlusButton: View {
    var rotated = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .rotationEffect(.degrees(rotated ? 45 : 0))
                .animation(.easeOut(duration: 0.2), value: rotated)
                .frame(width: 48, height: 48)
                .background(.white.opacity(0.10), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rotated ? "收起音色与语速" : "音色与语速")
    }
}

// MARK: - 场景练习（严格按剧本；手动触发 / 沉浸式共用）

/// 严格按剧本的场景练习：中文提示下一句该说什么、英文答案默认打码（点开才看）、
/// 说错逐句纠正指导、每句四维评分。手动触发=点击说话；沉浸式=麦克风常开自动判停。
struct ScenePracticeView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var rpStream: RoleplayStreamManager

    @State private var showVoicePanel = false
    @State private var keyboardMode = false
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    private var immersive: Bool { model.scenePracticeImmersive }
    @State private var guidanceItem: AppModel.HomeChatItem?

    var body: some View {
        Group {
            if immersive {
                // 沉浸式：与实时翻译同款的深色语音界面（圆形麦克风 + 随音量呼吸）
                ImmersivePracticeView(rpStream: rpStream)
            } else {
                manualBody
            }
        }
    }

    private var manualBody: some View {
        ZStack {
            RTTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if model.homeStatus.isEmpty == false {
                    Text(model.homeStatus)
                        .font(.system(size: 12 * model.fontScale))
                        .foregroundStyle(RTTheme.textSecondary)
                        .padding(.vertical, 6)
                }
                stream
                if showVoicePanel { InlineVoiceSpeedPanel().transition(.move(edge: .bottom)) }
                footer
            }
        }
        .sheet(item: $guidanceItem) { GuidanceDetailSheet(item: $0) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { model.exitScenePractice() } label: {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(RTTheme.textPrimary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.homeSceneName ?? "场景练习")
                    .font(.system(size: 15 * model.fontScale, weight: .semibold))
                    .foregroundStyle(RTTheme.textPrimary).lineLimit(1)
                Text(immersive ? "沉浸式 · 严格按剧本" : "手动触发 · 严格按剧本")
                    .font(.system(size: 11 * model.fontScale)).foregroundStyle(RTTheme.textSecondary)
            }
            Spacer()
            if let rp = model.roleplay {
                Text("\(rp.progress)/\(rp.total)")
                    .font(.system(size: 12 * model.fontScale, weight: .semibold))
                    .foregroundStyle(RTTheme.accent)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(RTTheme.accent.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var stream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.homeItems) { item in
                        ScenePracticeRow(item: item, onDetail: { guidanceItem = $0 }).id(item.id)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .onChange(of: model.homeItems.count) { _, _ in
                if let last = model.homeItems.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// 底部输入区：与原主界面一致的对称三段式。
    /// 常态「+ | 点击说话 | 键盘」；说话中「✕ | 波形 | ✓」；键盘态「输入框 | 发送 | 麦克风」。
    /// 沉浸式则中间换成「麦克风开关」（开着就一直听、自动判停成句）。
    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if keyboardMode {
                TextField("输入这一句的英文…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16 * model.fontScale))
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(RTTheme.hairline, lineWidth: 1))
                    .focused($draftFocused)
                Button {
                    let t = draft; draft = ""
                    model.sendHomeText(t)
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(RTTheme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button { keyboardMode = false; draftFocused = false } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 18)).foregroundStyle(RTTheme.textSecondary)
                        .frame(width: 40, height: 44)
                }
                .buttonStyle(.plain)
            } else if rpStream.manualRecording {
                // 说话中：左 ✕ 取消 / 中间波形 / 右侧 ✓ 发送
                Button { model.cancelHomeTalk() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(RTTheme.textSecondary)
                        .frame(width: 48, height: 48).background(RTTheme.surface, in: Circle())
                        .overlay(Circle().stroke(RTTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain).accessibilityLabel("取消这句话")

                TalkWaveBar(level: rpStream.audioLevel)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 25))
                    .overlay(RoundedRectangle(cornerRadius: 25).stroke(RTTheme.hairline, lineWidth: 1.5))

                Button { model.toggleHomeTalk() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 48, height: 48).background(RTTheme.accent, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("发送这句话")
            } else {
                // 左：「+」音色与语速（内联展开）
                Button { withAnimation(.easeOut(duration: 0.2)) { showVoicePanel.toggle() } } label: {
                    Image(systemName: showVoicePanel ? "xmark" : "plus")
                        .font(.system(size: 19, weight: .semibold)).foregroundStyle(RTTheme.textPrimary)
                        .frame(width: 48, height: 48).background(RTTheme.surface, in: Circle())
                        .overlay(Circle().stroke(RTTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain).accessibilityLabel("音色与语速")

                centerButton

                // 右：键盘输入（沉浸式也保留，方便打字补一句）
                Button { keyboardMode = true; draftFocused = true } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: 18)).foregroundStyle(RTTheme.textPrimary)
                        .frame(width: 48, height: 48).background(RTTheme.surface, in: Circle())
                        .overlay(Circle().stroke(RTTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain).accessibilityLabel("键盘输入")
            }
        }
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 10)
        .background(RTTheme.background)
    }

    /// 中间主按钮：断线=重连；沉浸式=麦克风开关；手动触发=点击说话。
    @ViewBuilder
    private var centerButton: some View {
        if rpStream.isConnected == false {
            // 注意：这里必须看 roleplay 流的连接状态（不是自由聊天的 homeConnected），
            // 否则一进来就误报断线，点重连还会连到自由聊天把旧聊天记录拉进来。
            Button { model.toggleHomeTalk() } label: {   // 内部会 afterTokenRefresh + reconnectStrictStream
                HStack(spacing: 8) {
                    ProgressView().tint(RTTheme.textSecondary)
                    Text("连接中…点击重试").foregroundStyle(RTTheme.textSecondary)
                }
                .font(.system(size: 16 * model.fontScale, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 25))
                .overlay(RoundedRectangle(cornerRadius: 25).stroke(RTTheme.hairline, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        } else if immersive {
            Button { rpStream.togglePause() } label: {
                HStack(spacing: 10) {
                    Image(systemName: rpStream.isPaused ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(rpStream.isPaused ? RTTheme.textSecondary : .white)
                    Text(rpStream.isPaused ? "麦克风已关 · 点击开启" : "聆听中 · 点击关闭")
                        .foregroundStyle(rpStream.isPaused ? RTTheme.textPrimary : .white)
                }
                .font(.system(size: 16 * model.fontScale, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(rpStream.isPaused ? AnyShapeStyle(RTTheme.surface) : AnyShapeStyle(RTTheme.accent),
                            in: RoundedRectangle(cornerRadius: 25))
                .overlay(RoundedRectangle(cornerRadius: 25)
                    .stroke(rpStream.isPaused ? RTTheme.hairline : .clear, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        } else {
            Button { model.toggleHomeTalk() } label: {
                HStack(spacing: 10) {
                    if model.homeWorking {
                        ProgressView().tint(RTTheme.textSecondary)
                        Text("请稍候…").foregroundStyle(RTTheme.textSecondary)
                    } else {
                        Image(systemName: "mic.fill").foregroundStyle(RTTheme.accent)
                        Text("点击说话").foregroundStyle(RTTheme.textPrimary)
                    }
                }
                .font(.system(size: 16 * model.fontScale, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 25))
                .overlay(RoundedRectangle(cornerRadius: 25).stroke(RTTheme.hairline, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(model.homeWorking)
        }
    }
}

/// 练习字幕行：AI 台词（默认打码，点开才看）/ 用户句 / 中文提示 / 指导 / 四维评分。
private struct ScenePracticeRow: View {
    @EnvironmentObject private var model: AppModel
    let item: AppModel.HomeChatItem
    var onDetail: (AppModel.HomeChatItem) -> Void = { _ in }

    var body: some View {
        switch item.kind {
        case .ai:       aiCard
        case .user:     userBubble
        case .hint:     hintCard
        case .guidance: guidanceCard
        case .score:    EmptyView()      // 评分已并入用户句下方的小按钮，不再单独占卡
        case .translate: EmptyView()
        }
    }

    private var aiCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .leading) {
                Text(item.text)
                    .font(.system(size: 15 * model.fontScale))
                    .foregroundStyle(RTTheme.textPrimary)
                    .blur(radius: item.masked ? 6 : 0)
                    .animation(.easeOut(duration: 0.22), value: item.masked)
                if item.masked {
                    Text("🙈 先听 · 点击显示英文")
                        .font(.system(size: 11 * model.fontScale, weight: .medium))
                        .foregroundStyle(RTTheme.textSecondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.toggleItemMasked(item.id) }
            Button { model.speakText(item.text, tone: item.tone) } label: {
                Image(systemName: "waveform").font(.system(size: 13)).foregroundStyle(RTTheme.accent)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RTTheme.hairline))
    }

    /// 用户句：气泡 + 下方一排小按钮（评分/发音指导），点开才看详情——不占屏。
    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(item.text)
                .font(.system(size: 15 * model.fontScale))
                .foregroundStyle(RTTheme.textPrimary)
                .padding(11)
                .background(RTTheme.userBubble, in: RoundedRectangle(cornerRadius: 14))
            if item.scores != nil || item.words.isEmpty == false {
                Button { onDetail(item) } label: {
                    HStack(spacing: 5) {
                        if let avg = averageScore {
                            Circle().fill(scoreColor(avg)).frame(width: 6, height: 6)
                            Text("本句 \(avg) 分")
                                .font(.system(size: 11 * model.fontScale, weight: .semibold))
                                .foregroundStyle(scoreColor(avg))
                        }
                        Text("发音与指导")
                            .font(.system(size: 11 * model.fontScale))
                            .foregroundStyle(RTTheme.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(RTTheme.textSecondary.opacity(0.7))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RTTheme.surface, in: Capsule())
                    .overlay(Capsule().stroke(RTTheme.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看本句评分与发音指导")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// 四维均分（小按钮上显示一个总印象分）。
    private var averageScore: Int? {
        guard let s = item.scores, s.isEmpty == false else { return nil }
        let vals = s.values.filter { $0 > 0 }
        guard vals.isEmpty == false else { return nil }
        return vals.reduce(0, +) / vals.count
    }

    /// 中文提示：接下来该说什么（英文答案默认打码，点开才显示）
    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text)
                .font(.system(size: 14 * model.fontScale, weight: .medium))
                .foregroundStyle(RTTheme.accent)
            if item.translation.isEmpty == false {
                ZStack(alignment: .leading) {
                    Text(item.translation)
                        .font(.system(size: 13 * model.fontScale))
                        .foregroundStyle(RTTheme.textPrimary)
                        .blur(radius: item.masked ? 6 : 0)
                        .animation(.easeOut(duration: 0.22), value: item.masked)
                    if item.masked {
                        Text("🙈 英文答案已隐藏 · 点击显示")
                            .font(.system(size: 11 * model.fontScale, weight: .medium))
                            .foregroundStyle(RTTheme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { model.toggleItemMasked(item.id) }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RTTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    /// 老师纠正：像对话里的一句话那样内联展示（左侧小灯泡 + 文字），不再是整块橙色卡片。
    private var guidanceCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 12)).foregroundStyle(.orange)
                .padding(.top, 2)
            Text(item.text)
                .font(.system(size: 14 * model.fontScale))
                .foregroundStyle(RTTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scoreColor(_ v: Int) -> Color {
        switch v {
        case 85...: return .green
        case 70..<85: return RTTheme.accent
        case 50..<70: return .orange
        default: return .red
        }
    }
}

// MARK: - 沉浸式场景练习（与实时翻译同款深色语音界面）

/// 沉浸式：深色底 + 底部光晕随音量呼吸 + 中央大圆形麦克风（随说话频率跳动）。
/// 严格按剧本：中文提示下一句、AI 台词打码点开、说错内联纠正。麦克风是开/关开关。
struct ImmersivePracticeView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var rpStream: RoleplayStreamManager

    @State private var showVoicePanel = false

    private var liveLevel: Double { rpStream.isAISpeaking ? rpStream.aiAudioLevel : rpStream.audioLevel }

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.08, blue: 0.10).ignoresSafeArea()
            RadialGradient(
                colors: [Color(red: 0.25, green: 0.47, blue: 0.85).opacity(0.28 + 0.5 * liveLevel),
                         Color(red: 0.16, green: 0.30, blue: 0.62).opacity(0.10 + 0.25 * liveLevel), .clear],
                center: UnitPoint(x: 0.5, y: 1.12), startRadius: 10, endRadius: 330 + 260 * liveLevel
            )
            .ignoresSafeArea().allowsHitTesting(false)
            .animation(.easeOut(duration: 0.12), value: liveLevel)

            VStack(spacing: 0) {
                header
                // 状态行紧贴顶栏，与下方字幕拉开距离
                statusLine.padding(.top, 6).padding(.bottom, 16)
                subtitles.frame(maxHeight: .infinity).clipped()   // 占满中间并裁剪，不盖住状态行
                // 「+」内联面板：与手动触发式同款（深色配色）
                if showVoicePanel {
                    InlineVoiceSpeedPanel(dark: true).transition(.move(edge: .bottom))
                }
                // 左「+」(音色/语速) + 中间大麦克风；整行固定高度，字幕不会被脉冲顶动
                HStack(spacing: 22) {
                    DarkPlusButton(rotated: showVoicePanel) {
                        withAnimation(.easeOut(duration: 0.2)) { showVoicePanel.toggle() }
                    }
                    micIndicator
                    Color.clear.frame(width: 48, height: 48)
                }
                .frame(height: 140)
                .padding(.bottom, 18)
                Text("严格按真实对话练 · 说错会当场纠正")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    .padding(.bottom, 10)
            }
        }
    }

    private var header: some View {
        HStack {
            Button { model.exitScenePractice() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    .padding(10).background(.white.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("退出练习")
            VStack(alignment: .leading, spacing: 1) {
                Text(model.homeSceneName ?? "场景练习")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text("沉浸式 · 严格按剧本")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            if let rp = model.roleplay {
                Text("\(rp.progress)/\(rp.total)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 18).padding(.top, 10)
    }

    private var statusLine: some View {
        Text(statusText)
            .font(.system(size: 15 * model.fontScale, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity)
    }

    private var statusText: String {
        if rpStream.isConnected == false { return "连接中…" }
        if rpStream.isAISpeaking { return "对方正在说…" }
        if rpStream.isPaused { return "麦克风已关闭" }
        if model.homeStatus.isEmpty == false { return model.homeStatus }
        return "按提示开口说英语"
    }

    /// 最近几条：中文提示 / AI 台词（打码点开）/ 纠正。始终滚到最新。
    private var subtitles: some View {
        ScrollViewReader { proxy in
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.homeItems.suffix(5)) { item in
                    switch item.kind {
                    case .hint:
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.text)
                                .font(.system(size: 16 * model.fontScale, weight: .semibold))
                                .foregroundStyle(Color(red: 0.36, green: 0.66, blue: 1.0))
                            if item.translation.isEmpty == false {
                                ZStack(alignment: .leading) {
                                    Text(item.translation)
                                        .font(.system(size: 14 * model.fontScale))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .blur(radius: item.masked ? 6 : 0)
                                    if item.masked {
                                        Text("🙈 英文答案已隐藏 · 点击显示")
                                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { model.toggleItemMasked(item.id) }
                            }
                        }
                    case .ai:
                        ZStack(alignment: .leading) {
                            Text(item.text)
                                .font(.system(size: 16 * model.fontScale))
                                .foregroundStyle(.white)
                                .blur(radius: item.masked ? 6 : 0)
                            if item.masked {
                                Text("🙈 先听 · 点击显示英文")
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.toggleItemMasked(item.id) }
                    case .user:
                        Text(item.text)
                            .font(.system(size: 15 * model.fontScale))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    case .guidance:
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "lightbulb.fill")
                                .font(.system(size: 11)).foregroundStyle(.orange).padding(.top, 2)
                            Text(item.text)
                                .font(.system(size: 14 * model.fontScale))
                                .foregroundStyle(.orange.opacity(0.95))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    default:
                        EmptyView()
                    }
                }
                Color.clear.frame(height: 1).id("immersive-bottom")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 14)
        }
        .onChange(of: model.homeItems.count) { _, _ in
            withAnimation { proxy.scrollTo("immersive-bottom", anchor: .bottom) }
        }
        }
    }

    /// 中央圆形麦克风：随音量呼吸跳动；断线时变重连。
    @ViewBuilder
    private var micIndicator: some View {
        if rpStream.isConnected == false {
            Button { model.toggleHomeTalk() } label: {
                HStack(spacing: 8) { Image(systemName: "arrow.clockwise"); Text("重连") }
                    .font(.system(size: 17 * model.fontScale, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 40).padding(.vertical, 15)
                    .background(.white, in: Capsule())
            }
        } else {
            Button { rpStream.togglePause() } label: {
                PulsingMic(level: liveLevel,
                           symbol: rpStream.isPaused ? "mic.slash.fill" : "mic.fill",
                           ringColor: rpStream.isAISpeaking ? RTTheme.success : RTTheme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(rpStream.isPaused ? "开启麦克风" : "关闭麦克风")
        }
    }
}

/// 「+」面板内联的音色 / 语速选择（不再跳子界面）。
struct InlineVoiceSpeedPanel: View {
    @EnvironmentObject private var model: AppModel
    /// dark=true：深色语音界面（实时翻译/沉浸式）用的配色；false=手动触发式浅色界面。
    var dark = false

    private let speeds: [(String, Double)] = [("正常", 1.0), ("慢 0.5×", 0.5), ("快 1.5×", 1.5), ("快 2×", 2.0)]

    private var labelColor: Color { dark ? .white.opacity(0.9) : RTTheme.textPrimary }
    private var chipText: Color { dark ? .white.opacity(0.9) : RTTheme.textPrimary }
    private var chipFill: AnyShapeStyle { dark ? AnyShapeStyle(.white.opacity(0.10)) : AnyShapeStyle(RTTheme.background) }
    private var chipStroke: Color { dark ? .white.opacity(0.18) : RTTheme.hairline }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("语速").font(.system(size: 13 * model.fontScale, weight: .semibold))
                    .foregroundStyle(labelColor)
                HStack(spacing: 8) {
                    ForEach(speeds, id: \.1) { name, value in
                        let selected = abs(model.playbackSpeed - value) < 0.01
                        Button { model.playbackSpeed = value } label: {
                            Text(name)
                                .font(.system(size: 12 * model.fontScale, weight: .medium))
                                .foregroundStyle(selected ? .white : chipText)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(selected ? AnyShapeStyle(RTTheme.accent) : chipFill, in: Capsule())
                                .overlay(Capsule().stroke(selected ? Color.clear : chipStroke))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("音色").font(.system(size: 13 * model.fontScale, weight: .semibold))
                    .foregroundStyle(labelColor)
                // 换行平铺：所有音色一眼看全，不用左右滑
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(model.ttsVoices, id: \.self) { v in
                        let selected = model.ttsCurrentVoice == v
                        Button { model.changeTutorVoice(v) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: VoiceInfo.isFemale(v) ? "person.fill" : "person")
                                    .font(.system(size: 11))
                                Text(v).lineLimit(1)
                            }
                            .font(.system(size: 12 * model.fontScale, weight: .medium))
                            .foregroundStyle(selected ? .white : chipText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(selected ? AnyShapeStyle(RTTheme.accent) : chipFill, in: Capsule())
                            .overlay(Capsule().stroke(selected ? Color.clear : chipStroke))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dark ? AnyShapeStyle(Color.white.opacity(0.06)) : AnyShapeStyle(RTTheme.surface))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(chipStroke), alignment: .top)
        .task { await model.loadTtsVoices() }
    }
}
