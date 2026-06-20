import SwiftUI

struct ImmersiveRoleplayView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var practiceSpeech: SpeechPracticeManager
    @EnvironmentObject private var voice: VoicePromptPlayer
    @Environment(\.dismiss) private var dismiss

    // 手工触发式：长按说话的手势状态
    @State private var manualPressing = false
    @State private var manualDragX: CGFloat = 0
    private let manualCancelThreshold: CGFloat = -70

    private enum Palette {
        // 深蓝调暗色背景（呼应品牌渐变的蓝端，同时保证字幕可读）
        static let top = Color(red: 0.07, green: 0.11, blue: 0.22)
        static let bottom = Color(red: 0.02, green: 0.03, blue: 0.08)
        static let listen = Color(red: 0.12, green: 0.74, blue: 0.38)
        static let speak = Color(red: 0.88, green: 0.18, blue: 0.18)
        static let thinking = Color(red: 0.32, green: 0.30, blue: 0.88)
        static let muted = Color.white.opacity(0.18)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.top, Palette.bottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                captions
                promptAndControl
            }
        }
        .preferredColorScheme(.dark)
    }

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
                    model.pauseVoiceConversation()
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

            // 对话中不可切换：只读展示当前方式（在设置里改）
            HStack(spacing: 8) {
                modeChip(model.conversationMode == .manual ? "手工触发式" : "沉浸式")
                modeChip(model.guidanceMode == .final ? "结束后指导" : "实时指导")
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var captions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(captionItems.enumerated()), id: \.offset) { idx, item in
                        captionRow(item, isCurrent: idx == captionItems.count - 1)
                            .id(idx)
                    }
                    Color.clear.frame(height: 24).id("bottom")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
            .onChange(of: captionItems.count) { _, _ in scrollDown(proxy) }
            .onChange(of: model.roleplay?.latestFeedback) { _, _ in scrollDown(proxy) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.3)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private func captionRow(_ item: Caption, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(item.speaker): \(item.text)")
                .font(.system(size: isCurrent ? 28 * model.fontScale : 22 * model.fontScale, weight: .semibold, design: .rounded))
                .foregroundStyle(item.color.opacity(isCurrent ? 1 : 0.50))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.showDialogueContent, item.translation.isEmpty == false {
                Text(item.translation)
                    .font(.system(size: 15 * model.fontScale))
                    .foregroundStyle(.white.opacity(isCurrent ? 0.62 : 0.32))
            }
        }
    }

    private var promptAndControl: some View {
        VStack(spacing: 12) {
            if let prompt = promptText {
                Text(prompt)
                    .font(.system(size: 17 * model.fontScale, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 22)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if model.conversationMode == .manual && isUserTurnNow {
                manualTalkControl
            } else {
                circleButton
            }

            Text(controlText)
                .font(.system(size: 13 * model.fontScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))

            // 完成后可一键重玩；「结束后指导」模式可随时取最终评分（中途退出也有评价）
            if model.roleplay?.completed == true {
                Button {
                    Task { await model.replayScenario() }
                } label: {
                    Label("重新对话", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 14 * model.fontScale, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .overlay(Capsule().stroke(.white.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            } else if model.guidanceMode == .final {
                Button {
                    Task { await model.requestFinalEvaluation() }
                } label: {
                    Text("查看评分与建议")
                        .font(.system(size: 14 * model.fontScale, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .overlay(Capsule().stroke(.white.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(model.isWorking)
                .padding(.bottom, 24)
            } else {
                Color.clear.frame(height: 24)
            }
        }
        .animation(.easeOut(duration: 0.22), value: promptText)
    }

    private func modeChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11 * model.fontScale, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.white.opacity(0.12), in: Capsule())
    }

    private var isUserTurnNow: Bool {
        model.roleplay?.completed == false
            && !model.isWorking
            && !voice.isSpeaking
            && model.roleplay?.nextLine != nil
            && model.isVoiceConversationActive
    }

    // 沉浸式：点击/自动聆听的圆形按钮
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
                        .frame(width: 86, height: 86)
                        .scaleEffect(circleScale(at: timeline.date))
                        .shadow(color: circleColor.opacity(0.35), radius: 24, y: 8)
                    if model.isWorking {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.2)
                    } else {
                        Image(systemName: circleIcon)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(model.roleplay?.completed == true ? .black.opacity(0.35) : .white)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(model.roleplay?.completed == true)
    }

    // 手工触发式：长按说话，左滑取消、右滑（或居中松手）发送
    private var manualTalkControl: some View {
        let willCancel = manualPressing && manualDragX < manualCancelThreshold
        return VStack(spacing: 14) {
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
                    .frame(width: 92, height: 92)
                    .scaleEffect(manualPressing ? 1.08 : 1)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                Image(systemName: manualPressing ? (willCancel ? "xmark" : "waveform") : "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
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
                        if cancel {
                            model.cancelManualUtterance()
                        } else {
                            model.sendManualUtterance()
                        }
                    }
            )
            .animation(.easeOut(duration: 0.15), value: manualPressing)
        }
    }

    private var promptText: String? {
        guard model.roleplay?.completed == false else { return nil }
        guard model.isWorking == false, voice.isSpeaking == false else { return nil }
        guard let next = model.roleplay?.nextLine else { return nil }
        let prefix = model.roleplay?.latestAccepted == false ? "请用英文继续说" : "请用英文说"
        return "\(prefix)：\(next.sourceText)"
    }

    private var controlText: String {
        if model.roleplay?.completed == true { return "本轮已完成" }
        if model.isWorking { return "等待后台处理" }
        if voice.isSpeaking { return "AI 正在说话，点击可停止" }
        if practiceSpeech.isListening {
            return model.conversationMode == .manual ? "松开发送 · 向左滑取消" : "正在听你说英语"
        }
        if model.isVoiceConversationActive == false { return "已暂停" }
        if model.conversationMode == .manual && isUserTurnNow { return "请长按并说话" }
        return "准备进入下一句"
    }

    private var circleColor: Color {
        if model.roleplay?.completed == true { return .white }
        if model.isWorking { return Palette.thinking }
        if voice.isSpeaking { return Palette.speak }
        if practiceSpeech.isListening { return Palette.listen }
        return Palette.muted
    }

    private var circleIcon: String {
        if model.roleplay?.completed == true { return "checkmark" }
        if voice.isSpeaking { return "stop.fill" }
        if practiceSpeech.isListening { return "waveform" }
        return model.isVoiceConversationActive ? "mic.fill" : "play.fill"
    }

    private func circleScale(at date: Date) -> CGFloat {
        if practiceSpeech.isListening {
            // 绿色：随用户说话的真实麦克风电平跳动
            return 1 + CGFloat(practiceSpeech.audioLevel) * 0.28
        }
        if voice.isSpeaking {
            // 红色：随 AI 实际朗读的逐词音律跳动（非固定正弦）
            return 1 + CGFloat(voice.audioLevel) * 0.28
        }
        return 1
    }

    private struct Caption {
        var speaker: String
        var text: String
        var translation: String
        var color: Color
    }

    private var captionItems: [Caption] {
        guard let rp = model.roleplay else { return [] }
        var items: [Caption] = []
        for msg in rp.messages {
            items.append(
                Caption(
                    speaker: msg.speaker == "user" ? "You" : "AI",
                    text: msg.content,
                    translation: msg.translation ?? "",
                    color: msg.speaker == "user" ? Color.white.opacity(0.92) : Color.white
                )
            )
            if model.guidanceMode == .realtime,
               msg.speaker == "user",
               let feedback = msg.feedback?.trimmingCharacters(in: .whitespacesAndNewlines),
               feedback.isEmpty == false {
                items.append(Caption(speaker: "AI", text: feedback, translation: "", color: Color(red: 1.0, green: 0.82, blue: 0.42)))
            }
        }
        // 实时模式展示每轮纠正；结束后指导模式仅在完成/按需评估时由 latestFeedback 给出最终建议
        if let feedback = rp.latestFeedback?.trimmingCharacters(in: .whitespacesAndNewlines),
           feedback.isEmpty == false,
           items.last?.text != feedback {
            items.append(Caption(speaker: "AI", text: feedback, translation: "", color: Color(red: 1.0, green: 0.82, blue: 0.42)))
        }
        return items
    }
}
