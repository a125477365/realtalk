import SwiftUI

/// 对话界面拆为两个区：
/// - 字幕区：只显示 AI 与用户已确认的对话内容，可实时切换双语/仅英文。
/// - 指导区：显示「下一句要说的中文提示」（仅展示、不语音播报）；实时指导时显示 AI 的中文纠正建议
///   （纠正会用中文语音播报），结束后指导时仅在结束后显示并播报最终评分与建议。
struct ImmersiveRoleplayView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var practiceSpeech: SpeechPracticeManager
    @EnvironmentObject private var voice: VoicePromptPlayer
    @EnvironmentObject private var stream: RoleplayStreamManager
    @Environment(\.dismiss) private var dismiss

    // 手工触发式：长按说话的手势状态
    @State private var manualPressing = false
    @State private var manualDragX: CGFloat = 0
    private let manualCancelThreshold: CGFloat = -70

    private enum Palette {
        static let top = Color(red: 0.07, green: 0.11, blue: 0.22)
        static let bottom = Color(red: 0.02, green: 0.03, blue: 0.08)
        static let listen = Color(red: 0.12, green: 0.74, blue: 0.38)   // 聆听绿
        static let speak = Color(red: 0.96, green: 0.70, blue: 0.11)    // 可打断黄（AI 说话时可开口打断）
        static let thinking = Color(red: 0.88, green: 0.18, blue: 0.18) // 后端处理红（不能打断）
        static let muted = Color.white.opacity(0.18)
        static let guide = Color(red: 1.0, green: 0.82, blue: 0.42)   // 指导/纠正色
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.top, Palette.bottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                header
                subtitlePane        // 上：字幕区（已确认对话）
                if model.roleplay?.completed == true {
                    reviewCard      // 完成：最终评分卡（分数 + 建议）
                } else {
                    guidancePane    // 中：指导区（提示 + 纠正/评分）
                }
                controlBar          // 下：麦克风与控制
            }
        }
        .preferredColorScheme(.dark)
        // 对话被系统/模型/额度异常中断时弹失败提示框（沉浸式界面也能看到原因）
        .alert(item: $model.failureAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("我知道了")))
        }
    }

    // MARK: 顶栏

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.scenario?.title ?? "对练")
                        .font(.system(size: 17 * model.fontScale, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let rp = model.roleplay {
                        Text("第 \(min(rp.progress + 1, rp.total)) / \(rp.total) 句 · 我演 \(model.roleName(rp.selectedRole))")
                            .font(.system(size: 12 * model.fontScale))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                }
                Spacer()
                Button {
                    model.exitConversation()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: 字幕区（只显示已确认对话；可切换双语/仅英文）

    private var subtitlePane: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(subtitleItems.enumerated()), id: \.offset) { idx, item in
                            captionRow(item, isCurrent: idx == subtitleItems.count - 1)
                        }
                        Color.clear.frame(height: 8).id("subBottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .onChange(of: subtitleItems.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("subBottom", anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // 微信式气泡：AI 在左、我（You）在右；中文翻译小字是否显示由「中文提示」开关控制
    private func captionRow(_ item: Caption, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if item.isUser { Spacer(minLength: 44) }
            VStack(alignment: item.isUser ? .trailing : .leading, spacing: 5) {
                Text(item.text)
                    .font(.system(size: (isCurrent ? 20 : 18) * model.fontScale, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.7))
                    .lineSpacing(3)
                    .multilineTextAlignment(item.isUser ? .trailing : .leading)
                if model.showChineseHint, item.translation.isEmpty == false {
                    Text(item.translation)
                        .font(.system(size: 14 * model.fontScale))
                        .foregroundStyle(.white.opacity(isCurrent ? 0.62 : 0.34))
                        .multilineTextAlignment(item.isUser ? .trailing : .leading)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                item.isUser ? AnyShapeStyle(Palette.listen.opacity(0.85)) : AnyShapeStyle(Color.white.opacity(0.10)),
                in: RoundedRectangle(cornerRadius: 16)
            )
            if item.isUser == false { Spacer(minLength: 44) }
        }
    }

    // MARK: 指导区（下一句中文提示 + 纠正/评分；提示仅展示不播报）

    private var guidancePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let hint = nextLineHint {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "text.bubble")
                                    .foregroundStyle(.white.opacity(0.7))
                                Text(hint)
                                    .font(.system(size: 16 * model.fontScale, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if let englishHint = model.practiceHintText {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "quote.bubble")
                                    .foregroundStyle(.white.opacity(0.7))
                                Text(englishHint)
                                    .font(.system(size: 15 * model.fontScale, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        ForEach(Array(guidanceItems.enumerated()), id: \.offset) { _, text in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "lightbulb")
                                    .foregroundStyle(Palette.guide)
                                Text(text)
                                    .font(.system(size: 14 * model.fontScale))
                                    .foregroundStyle(Palette.guide)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if nextLineHint == nil && guidanceItems.isEmpty {
                            Text(model.guidanceMode == .final ? "结束后会给出整体评分与建议" : "AI 的中文纠正建议会显示在这里")
                                .font(.system(size: 13 * model.fontScale))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Color.clear.frame(height: 4).id("guideBottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.hidden)
                .onChange(of: guidanceItems.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("guideBottom", anchor: .bottom) }
                }
            }
        }
        .frame(height: 168)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.10)))
        .padding(.horizontal, 12)
    }

    // MARK: 完成评分卡（分数 + 建议）

    private var reviewCard: some View {
        VStack(spacing: 8) {
            Text("\(Int(((model.roleplay?.score ?? 0) * 100).rounded()))")
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("本轮口语得分")
                .font(.system(size: 12 * model.fontScale))
                .foregroundStyle(.white.opacity(0.6))
            ScrollView {
                Text(reviewAnalysis)
                    .font(.system(size: 14 * model.fontScale))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineSpacing(3)
            }
            .scrollIndicators(.hidden)
        }
        .padding(16)
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
        .padding(.horizontal, 12)
    }

    /// 评分卡的分析文字：去掉与大号分数重复的「最终评分 N/100。」前缀。
    private var reviewAnalysis: String {
        let fb = (model.roleplay?.latestFeedback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if fb.hasPrefix("最终评分"), let dot = fb.firstIndex(of: "。") {
            let rest = String(fb[fb.index(after: dot)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? "本轮已完成，可点「重新对话」再练一次。" : rest
        }
        return fb.isEmpty ? "本轮已完成，可点「重新对话」再练一次。" : fb
    }

    // MARK: 控制区（麦克风 + 状态 + 重玩/评分按钮）

    private var controlBar: some View {
        VStack(spacing: 10) {
            if model.conversationMode == .manual && isUserTurnNow {
                manualTalkControl
            } else {
                circleButton
            }

            Text(controlText)
                .font(.system(size: 13 * model.fontScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))

            if model.roleplay?.completed == true {
                Button {
                    Task { await model.replayScenario() }
                } label: {
                    Label("重新对话", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 14 * model.fontScale, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .overlay(Capsule().stroke(.white.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 20)
            } else {
                // 不再显示「查看评分与建议」按钮：完成对话后会自动展示评分卡
                Color.clear.frame(height: 20)
            }
        }
    }

    private var isUserTurnNow: Bool {
        model.roleplay?.completed == false
            && !model.isWorking
            && !voice.isSpeaking
            && model.roleplay?.nextLine != nil
            && model.isVoiceConversationActive
    }

    private var circleButton: some View {
        Button {
            if voice.isSpeaking {
                model.interruptAIAndContinue()
            } else if model.roleplay?.completed != true && model.isWorking == false {
                Task { await model.toggleVoiceConversation() }
            }
        } label: {
            TimelineView(.animation) { timeline in
                ZStack {
                    Circle()
                        .fill(circleColor)
                        .frame(width: 82, height: 82)
                        .scaleEffect(circleScale(at: timeline.date))
                        .shadow(color: circleColor.opacity(0.35), radius: 24, y: 8)
                    if model.isWorking {
                        ProgressView().tint(.white).scaleEffect(1.2)
                    } else {
                        Image(systemName: circleIcon)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(model.roleplay?.completed == true ? .black.opacity(0.35) : .white)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(model.roleplay?.completed == true)
    }

    private var manualTalkControl: some View {
        let willCancel = manualPressing && manualDragX < manualCancelThreshold
        return VStack(spacing: 12) {
            if manualPressing {
                Text(practiceSpeech.partialText.isEmpty ? "请说英文…" : practiceSpeech.partialText)
                    .font(.system(size: 16 * model.fontScale))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 20)
                HStack {
                    Label("取消", systemImage: "xmark")
                        .foregroundStyle(willCancel ? .red : .white.opacity(0.55))
                        .scaleEffect(willCancel ? 1.15 : 1)
                    Spacer()
                    Label("发送", systemImage: "paperplane.fill")
                        .foregroundStyle(willCancel ? .white.opacity(0.55) : Palette.listen)
                        .scaleEffect(willCancel ? 1 : 1.15)
                }
                .font(.system(size: 14 * model.fontScale, weight: .semibold))
                .padding(.horizontal, 40)
            }
            ZStack {
                Circle()
                    .fill(willCancel ? Color.red : (manualPressing ? Palette.listen : Palette.thinking))
                    .frame(width: 88, height: 88)
                    .scaleEffect(manualPressing ? 1.08 : 1)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                Image(systemName: manualPressing ? (willCancel ? "xmark" : "waveform") : "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !manualPressing {
                            manualPressing = true
                            Task { await model.beginManualUtterance() }
                        }
                        manualDragX = value.translation.width
                    }
                    .onEnded { _ in
                        let cancel = manualDragX < manualCancelThreshold
                        manualPressing = false
                        manualDragX = 0
                        if cancel { model.cancelManualUtterance() } else { model.sendManualUtterance() }
                    }
            )
            .animation(.easeOut(duration: 0.15), value: manualPressing)
        }
    }

    /// 下一句要说的中文提示（仅展示、不语音播报）。实时/事后指导都会提示。
    private var nextLineHint: String? {
        guard model.roleplay?.completed == false, let next = model.roleplay?.nextLine else { return nil }
        // 指导区永远给中文提示（与「中文提示」开关无关；开关只管字幕里的中文翻译）
        let prefix = model.roleplay?.latestAccepted == false ? "请你用英文继续说" : "请你用英文说"
        return "\(prefix)：\(next.sourceText)"
    }

    // AI 是否正在说话：手动式用本地 TTS(voice)、沉浸式用流(stream)
    private var aiSpeakingNow: Bool { voice.isSpeaking || stream.isAISpeaking }

    private var controlText: String {
        if model.roleplay?.completed == true { return "本轮已完成" }
        if model.isWorking { return "已发送，正在识别评分…" }        // 红：后端处理，不能打断
        if aiSpeakingNow { return "AI 正在说话，开口即可打断" }       // 黄：可打断
        if model.isVoiceConversationActive == false { return "已暂停，点击继续" }
        if model.conversationMode == .manual {
            return practiceSpeech.isListening ? "松开发送 · 向左滑取消" : "请长按并说话"
        }
        return "正在聆听，说完停顿即可发送"                          // 绿：聆听
    }

    private var circleColor: Color {
        if model.roleplay?.completed == true { return .white }
        if model.isWorking { return Palette.thinking }              // 红
        if aiSpeakingNow { return Palette.speak }                    // 黄
        if model.isVoiceConversationActive == false { return Palette.muted }
        // 手动式等待长按时不显示绿色（尚未在录音）
        if model.conversationMode == .manual && practiceSpeech.isListening == false { return Palette.muted }
        return Palette.listen                                        // 绿
    }

    private var circleIcon: String {
        if model.roleplay?.completed == true { return "checkmark" }
        if voice.isSpeaking { return "stop.fill" }
        if practiceSpeech.isListening { return "waveform" }
        return model.isVoiceConversationActive ? "mic.fill" : "play.fill"
    }

    private func circleScale(at date: Date) -> CGFloat {
        // 沉浸式后端语音流：跳动跟随流的电平
        if stream.isAISpeaking { return 1 + CGFloat(stream.aiAudioLevel) * 0.28 }
        if stream.audioLevel > 0.02 { return 1 + CGFloat(stream.audioLevel) * 0.28 }
        if practiceSpeech.isListening { return 1 + CGFloat(practiceSpeech.audioLevel) * 0.28 }
        if voice.isSpeaking { return 1 + CGFloat(voice.audioLevel) * 0.28 }
        return 1
    }

    private struct Caption {
        var speaker: String
        var text: String
        var translation: String
        var color: Color
        var isUser: Bool
    }

    /// 字幕区：只含 AI 与用户的已确认对话内容（不含纠正建议）。
    private var subtitleItems: [Caption] {
        guard let rp = model.roleplay else { return [] }
        return rp.messages.map { msg in
            Caption(
                speaker: msg.speaker == "user" ? "You" : "AI",
                text: msg.content,
                translation: msg.translation ?? "",
                color: msg.speaker == "user" ? Color.white.opacity(0.92) : Color.white,
                isUser: msg.speaker == "user"
            )
        }
    }

    /// 指导区：实时指导=每轮中文纠正；结束后指导=结束后的整体评分与建议。
    /// 指导区只显示「当前这句」的纠正建议：说错时给出更自然的英文，说对/进入下一句即清空。
    /// 不再累积历史每轮反馈，也不把「正确…」之类的确认语当成提示展示（避免被误当成要翻译的中文）。
    private var guidanceItems: [String] {
        guard let rp = model.roleplay, model.guidanceMode == .realtime else { return [] }
        let fb = (rp.latestFeedback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard fb.isEmpty == false,
              fb.hasPrefix("正确") == false,
              fb.hasPrefix("回答正确") == false else { return [] }
        return [fb]
    }
}
