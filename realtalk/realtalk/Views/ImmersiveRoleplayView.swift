import SwiftUI

/// 沉浸式对练字幕：深色影院式背景，大字幕随对话自动上滚。
/// AI 句中英双语同显；轮到用户先显示中文提示，开口后显示英文识别与纠错标注。
struct ImmersiveRoleplayView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var practiceSpeech: SpeechPracticeManager
    @EnvironmentObject private var voice: VoicePromptPlayer
    @Environment(\.dismiss) private var dismiss

    private enum Palette {
        static let top = Color(red: 0.16, green: 0.13, blue: 0.42)
        static let bottom = Color(red: 0.05, green: 0.04, blue: 0.14)
        static let accent = Color(red: 0.55, green: 0.52, blue: 0.98)   // 亮靛蓝
        static let good = Color(red: 0.40, green: 0.85, blue: 0.55)
        static let warn = Color(red: 0.98, green: 0.78, blue: 0.36)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.top, Palette.bottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                captions
                controls
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 顶栏：进度 / 标题 / 关闭

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.scenario?.title ?? "对练")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let rp = model.roleplay {
                    Text("第 \(min(rp.progress + 1, rp.total)) / \(rp.total) 句 · 我演 \(model.roleName(rp.selectedRole))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
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
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: 字幕区（自动上滚）

    private var captions: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Color.clear.frame(height: 12)
                    ForEach(Array(captionItems.enumerated()), id: \.offset) { idx, item in
                        captionRow(item, isCurrent: idx == captionItems.count - 1)
                            .id(idx)
                    }
                    // 用户开口时的实时识别字幕
                    if practiceSpeech.partialText.isEmpty == false {
                        Text(practiceSpeech.partialText)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("partial")
                    }
                    Color.clear.frame(height: 24).id("bottom")
                }
                .padding(.horizontal, 22)
            }
            .scrollIndicators(.hidden)
            .onChange(of: captionItems.count) { _, _ in scrollDown(proxy) }
            .onChange(of: practiceSpeech.partialText) { _, _ in scrollDown(proxy) }
            .onChange(of: model.roleplay?.latestFeedback) { _, _ in scrollDown(proxy) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    @ViewBuilder
    private func captionRow(_ item: Caption, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.speaker)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(item.isUser ? Palette.accent : .white.opacity(0.5))
                .textCase(.uppercase)

            if item.awaitingUser {
                // 轮到用户：先给中文提示
                Text("该你说")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text(item.chinese)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                // 英文主字幕
                Text(item.english)
                    .font(.system(size: isCurrent ? 30 : 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.42))
                if item.chinese.isEmpty == false {
                    Text(item.chinese)
                        .font(.system(size: isCurrent ? 17 : 15))
                        .foregroundStyle(.white.opacity(isCurrent ? 0.7 : 0.3))
                }
                // 纠错标注
                if let note = item.note, note.isEmpty == false {
                    Label(note, systemImage: item.accepted ? "checkmark.circle.fill" : "lightbulb.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(item.accepted ? Palette.good : Palette.warn)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 底部控制

    private var controls: some View {
        VStack(spacing: 14) {
            Text(statusText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))

            HStack(spacing: 28) {
                controlButton(icon: "speaker.wave.2.fill", label: "重听") {
                    model.replayLastAI()
                }
                Button {
                    Task { await model.toggleVoiceConversation() }
                } label: {
                    ZStack {
                        Circle().fill(model.isVoiceConversationActive ? Palette.accent : .white.opacity(0.18))
                            .frame(width: 76, height: 76)
                        Image(systemName: model.isVoiceConversationActive ? "waveform" : "mic.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                controlButton(icon: "lightbulb.fill", label: "提示") {
                    Task { await model.sendMainChatMessage("提示") }
                }
            }
        }
        .padding(.bottom, 28)
        .padding(.top, 10)
    }

    private func controlButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 50, height: 50)
                    .background(.white.opacity(0.1), in: Circle())
                Text(label).font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
    }

    private var statusText: String {
        if voice.isSpeaking { return "AI 正在说…" }
        if practiceSpeech.isListening { return "请用英语说出这句" }
        if model.roleplay?.completed == true { return "这轮练习已完成 🎉" }
        if model.isVoiceConversationActive == false { return "已暂停，点麦克风继续" }
        return "准备好了就开口说"
    }

    // MARK: 字幕数据组装

    private struct Caption {
        var speaker: String
        var english: String
        var chinese: String
        var note: String?
        var accepted: Bool
        var isUser: Bool
        var awaitingUser: Bool
    }

    private var captionItems: [Caption] {
        guard let rp = model.roleplay else { return [] }
        var items: [Caption] = rp.messages.map { msg in
            let isUser = msg.speaker == "user"
            return Caption(
                speaker: isUser ? "我" : model.roleName(msg.role),
                english: msg.content,
                chinese: msg.translation ?? "",
                note: isUser ? msg.feedback : nil,
                accepted: (msg.feedback ?? "").isEmpty,
                isUser: isUser,
                awaitingUser: false
            )
        }
        // 轮到用户、且尚未开口：追加中文提示卡
        if rp.completed == false, let next = rp.nextLine,
           practiceSpeech.partialText.isEmpty,
           (rp.messages.last?.speaker != "user") {
            items.append(Caption(
                speaker: "我", english: "", chinese: next.sourceText,
                note: nil, accepted: true, isUser: true, awaitingUser: true
            ))
        }
        return items
    }
}
