import SwiftUI

/// AI英语私教（一对一语音老师）：无场景、无指导区，只有字幕流。
/// 老师的讲解/纠正直接作为对话字幕显示并朗读；说话即抢话打断；底部音频圆钮点按可临时暂停/恢复。
struct FreeTalkView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var stream: RoleplayStreamManager

    var body: some View {
        ZStack {
            // 沉浸式同款深色底
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.10), Color(red: 0.09, green: 0.10, blue: 0.16)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                subtitles
                controls
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI英语私教")
                    .font(.system(size: 17 * model.fontScale, weight: .semibold))
                    .foregroundStyle(.white)
                Text("一对一语音老师 · 想聊什么直接说，可以问语法、单词，或说「练一个打车场景」")
                    .font(.system(size: 11 * model.fontScale))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button {
                model.stopFreeTalk()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(10)
                    .background(.white.opacity(0.12), in: Circle())
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var subtitles: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.freeTalkMessages) { line in
                        HStack {
                            if line.speaker == "user" { Spacer(minLength: 40) }
                            Text(line.text)
                                .font(.system(size: 15 * model.fontScale))
                                .foregroundStyle(line.speaker == "user" ? Color.white : Color.white.opacity(0.92))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    line.speaker == "user"
                                        ? AnyShapeStyle(RTTheme.accent.opacity(0.85))
                                        : AnyShapeStyle(Color.white.opacity(0.10)),
                                    in: RoundedRectangle(cornerRadius: 16)
                                )
                            if line.speaker != "user" { Spacer(minLength: 40) }
                        }
                        .id(line.id)
                    }
                    if model.freeTalkMessages.isEmpty {
                        Text(model.freeTalkStatus.isEmpty ? "老师马上开口，直接用英语聊起来吧" : model.freeTalkStatus)
                            .font(.system(size: 13 * model.fontScale))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 60)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: model.freeTalkMessages.count) { _, _ in
                if let last = model.freeTalkMessages.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    // 与沉浸式同款：随音频电平跳动的状态圆钮；点按 = 临时暂停 / 恢复
    private var controls: some View {
        VStack(spacing: 10) {
            if model.freeTalkStatus.isEmpty == false, model.freeTalkMessages.isEmpty == false {
                Text(model.freeTalkStatus)
                    .font(.system(size: 12 * model.fontScale))
                    .foregroundStyle(.yellow.opacity(0.9))
            }
            Button {
                stream.togglePause()
            } label: {
                ZStack {
                    Circle()
                        .fill(circleColor)
                        .frame(width: 82, height: 82)
                        .scaleEffect(1 + 0.28 * (stream.isAISpeaking ? stream.aiAudioLevel : stream.audioLevel))
                        .shadow(color: circleColor.opacity(0.35), radius: 24, y: 8)
                    Image(systemName: stream.isPaused ? "play.fill" : (stream.isAISpeaking ? "speaker.wave.2.fill" : "mic.fill"))
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .animation(.easeOut(duration: 0.12), value: stream.audioLevel)

            Text(statusLabel)
                .font(.system(size: 13 * model.fontScale, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .padding(.bottom, 24)
        }
    }

    private var circleColor: Color {
        if stream.isPaused { return Color.white.opacity(0.25) }
        if stream.isAISpeaking { return RTTheme.accent }
        return RTTheme.success
    }

    private var statusLabel: String {
        if stream.isPaused { return "已暂停，点击继续" }
        if stream.isAISpeaking { return "老师正在说话，开口即可打断" }
        return "正在聆听，你说完稍停即发送 · 点击可暂停"
    }
}
