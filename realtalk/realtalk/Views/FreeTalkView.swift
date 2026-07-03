import SwiftUI

/// 自由对话（一对一语音英语老师）：无场景、无指导区，只有字幕流。
/// 老师的讲解/纠正直接作为对话字幕显示并朗读；可随时开口（说话即抢话打断老师）。
struct FreeTalkView: View {
    @EnvironmentObject private var model: AppModel

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
                Text("自由对话")
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

    private var controls: some View {
        VStack(spacing: 8) {
            if model.freeTalkStatus.isEmpty == false, model.freeTalkMessages.isEmpty == false {
                Text(model.freeTalkStatus)
                    .font(.system(size: 12 * model.fontScale))
                    .foregroundStyle(.yellow.opacity(0.9))
            }
            HStack(spacing: 14) {
                // 电平指示：老师说话/自己说话
                Circle()
                    .fill(model.freeStream.isAISpeaking ? RTTheme.accent : Color.green)
                    .frame(width: 10, height: 10)
                    .opacity(0.5 + 0.5 * (model.freeStream.isAISpeaking ? model.freeStream.aiAudioLevel : model.freeStream.audioLevel))
                Text(model.freeStream.isAISpeaking ? "老师正在说话，开口即可打断" : "正在聆听，你说完稍停即发送")
                    .font(.system(size: 12 * model.fontScale))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.bottom, 24)
        }
    }
}
