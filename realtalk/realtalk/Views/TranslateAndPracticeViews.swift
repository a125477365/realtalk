import SwiftUI

// MARK: - 实时翻译（主界面右上角「A中」进入，全屏）

/// 实时翻译：说中文→听到英文，说英文→听到中文（边说边出，服务端自动分句）。
/// 退出时把本次全部原文交给后台智能生成英文场景（可能切分成多个场景），回到主界面即可练。
struct TranslateCallView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var stream: RoleplayStreamManager

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
                statusLine.padding(.top, 14)
                subtitles
                Spacer(minLength: 12)
                micIndicator.padding(.bottom, 26)
                Text("翻译内容会自动整理成英文场景，可回主界面练习")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    .padding(.bottom, 10)
            }
        }
        .onAppear { model.startTutor() }
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

    /// 最近几条成对字幕：原文 + 蓝色译文。
    private var subtitles: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                ForEach(model.homeItems.filter { $0.kind == .translate }.suffix(6)) { item in
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
                }
            }
            .padding(.horizontal, 24).padding(.top, 16)
        }
        .frame(maxHeight: 320)
    }

    private func replay(_ text: String) -> some View {
        Button { model.speakText(text) } label: {
            Image(systemName: "waveform").font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
        .accessibilityLabel("重播译文")
    }

    private func isChinese(_ s: String) -> Bool {
        let cjk = s.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        let letters = s.unicodeScalars.filter { ("a"..."z").contains(Character($0)) || ("A"..."Z").contains(Character($0)) }.count
        return cjk > 0 && cjk >= letters
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
                ZStack {
                    Circle().stroke(RTTheme.accent.opacity(0.35 + 0.4 * liveLevel), lineWidth: 2)
                        .frame(width: 96 + 34 * liveLevel, height: 96 + 34 * liveLevel)
                    Circle().fill(.white.opacity(0.10)).frame(width: 84, height: 84)
                        .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                    Image(systemName: stream.isPaused ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .medium)).foregroundStyle(.white)
                        .scaleEffect(1 + 0.18 * liveLevel)
                }
                .animation(.easeOut(duration: 0.1), value: liveLevel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(stream.isPaused ? "开启麦克风" : "关闭麦克风")
        }
    }
}

// MARK: - 场景练习（严格按剧本；手动触发 / 沉浸式共用）

/// 严格按剧本的场景练习：中文提示下一句该说什么、英文答案默认打码（点开才看）、
/// 说错逐句纠正指导、每句四维评分。手动触发=点击说话；沉浸式=麦克风常开自动判停。
struct ScenePracticeView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var rpStream: RoleplayStreamManager

    @State private var showVoicePanel = false

    private var immersive: Bool { model.scenePracticeImmersive }

    var body: some View {
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
                        ScenePracticeRow(item: item).id(item.id)
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

    private var footer: some View {
        HStack(spacing: 12) {
            // 「+」只保留音色与语速，且直接在本面板内联展示（不再跳子界面）
            Button { withAnimation(.easeOut(duration: 0.2)) { showVoicePanel.toggle() } } label: {
                Image(systemName: showVoicePanel ? "xmark" : "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(RTTheme.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(RTTheme.surface, in: Circle())
                    .overlay(Circle().stroke(RTTheme.hairline))
            }
            .accessibilityLabel("音色与语速")

            if model.homeConnected == false {
                Button { model.reconnectTutor() } label: {
                    Text("连接中断，点击重连")
                        .font(.system(size: 15 * model.fontScale, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(RTTheme.accent, in: Capsule())
                }
            } else if immersive {
                // 沉浸式：麦克风就是「开/关」开关，开着就一直听、自动判停成句
                Button { rpStream.togglePause() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: rpStream.isPaused ? "mic.slash.fill" : "mic.fill")
                        Text(rpStream.isPaused ? "麦克风已关闭 · 点击开启" : "聆听中 · 点击关闭麦克风")
                    }
                    .font(.system(size: 15 * model.fontScale, weight: .semibold))
                    .foregroundStyle(rpStream.isPaused ? RTTheme.textSecondary : .white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(rpStream.isPaused ? AnyShapeStyle(RTTheme.surface) : AnyShapeStyle(RTTheme.accent),
                                in: Capsule())
                    .overlay(Capsule().stroke(rpStream.isPaused ? RTTheme.hairline : Color.clear))
                }
            } else {
                // 手动触发：按下说、再点发送
                Button {
                    if rpStream.manualRecording { rpStream.endManualUtterance() }
                    else { rpStream.beginManualUtterance() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: rpStream.manualRecording ? "arrow.up.circle.fill" : "mic.fill")
                        Text(rpStream.manualRecording ? "点击发送" : "点击说话")
                    }
                    .font(.system(size: 15 * model.fontScale, weight: .semibold))
                    .foregroundStyle(rpStream.manualRecording ? .white : RTTheme.textPrimary)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(rpStream.manualRecording ? AnyShapeStyle(RTTheme.accent) : AnyShapeStyle(RTTheme.surface),
                                in: Capsule())
                    .overlay(Capsule().stroke(rpStream.manualRecording ? Color.clear : RTTheme.hairline))
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(RTTheme.background)
    }
}

/// 练习字幕行：AI 台词（默认打码，点开才看）/ 用户句 / 中文提示 / 指导 / 四维评分。
private struct ScenePracticeRow: View {
    @EnvironmentObject private var model: AppModel
    let item: AppModel.HomeChatItem

    var body: some View {
        switch item.kind {
        case .ai:       aiCard
        case .user:     userBubble
        case .hint:     hintCard
        case .guidance: guidanceCard
        case .score:    scoreCard
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

    private var userBubble: some View {
        Text(item.text)
            .font(.system(size: 15 * model.fontScale))
            .foregroundStyle(RTTheme.textPrimary)
            .padding(11)
            .background(RTTheme.userBubble, in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: .infinity, alignment: .trailing)
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

    private var guidanceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill").font(.system(size: 12)).foregroundStyle(.orange)
                Text("老师指导").font(.system(size: 12 * model.fontScale, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            Text(item.text).font(.system(size: 14 * model.fontScale)).foregroundStyle(RTTheme.textPrimary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }

    private var scoreCard: some View {
        let dims: [(String, String)] = [("pronunciation", "发音"), ("grammar", "语法"),
                                        ("naturalness", "自然度"), ("vocabulary", "词汇")]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill").font(.system(size: 12)).foregroundStyle(RTTheme.accent)
                Text("本句评分").font(.system(size: 12 * model.fontScale, weight: .semibold))
                    .foregroundStyle(RTTheme.accent)
            }
            HStack(spacing: 10) {
                ForEach(dims, id: \.0) { key, label in
                    let v = item.scores?[key] ?? 0
                    VStack(spacing: 4) {
                        Text("\(v)").font(.system(size: 18 * model.fontScale, weight: .bold, design: .rounded))
                            .foregroundStyle(color(v))
                        Text(label).font(.system(size: 11 * model.fontScale))
                            .foregroundStyle(RTTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RTTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func color(_ v: Int) -> Color {
        switch v {
        case 85...: return .green
        case 70..<85: return RTTheme.accent
        case 50..<70: return .orange
        default: return .red
        }
    }
}

/// 「+」面板内联的音色 / 语速选择（不再跳子界面）。
struct InlineVoiceSpeedPanel: View {
    @EnvironmentObject private var model: AppModel

    private let speeds: [(String, Double)] = [("正常", 1.0), ("慢 0.5×", 0.5), ("快 1.5×", 1.5), ("快 2×", 2.0)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("语速").font(.system(size: 13 * model.fontScale, weight: .semibold))
                    .foregroundStyle(RTTheme.textPrimary)
                HStack(spacing: 8) {
                    ForEach(speeds, id: \.1) { name, value in
                        let selected = abs(model.playbackSpeed - value) < 0.01
                        Button { model.playbackSpeed = value } label: {
                            Text(name)
                                .font(.system(size: 12 * model.fontScale, weight: .medium))
                                .foregroundStyle(selected ? .white : RTTheme.textPrimary)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(selected ? AnyShapeStyle(RTTheme.accent) : AnyShapeStyle(RTTheme.surface),
                                            in: Capsule())
                                .overlay(Capsule().stroke(selected ? Color.clear : RTTheme.hairline))
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("音色").font(.system(size: 13 * model.fontScale, weight: .semibold))
                    .foregroundStyle(RTTheme.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.ttsVoices, id: \.self) { v in
                            let selected = model.ttsCurrentVoice == v
                            Button { model.changeTutorVoice(v) } label: {
                                Text("\(v) · \(VoiceInfo.langBadge(v))")
                                    .font(.system(size: 12 * model.fontScale, weight: .medium))
                                    .foregroundStyle(selected ? .white : RTTheme.textPrimary)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(selected ? AnyShapeStyle(RTTheme.accent) : AnyShapeStyle(RTTheme.surface),
                                                in: Capsule())
                                    .overlay(Capsule().stroke(selected ? Color.clear : RTTheme.hairline))
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RTTheme.surface)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(RTTheme.hairline), alignment: .top)
        .task { await model.loadTtsVoices() }
    }
}
