import SwiftUI

/// 高级会员「实时语音大模型」沉浸式对练界面（需求第 4 项）。
/// 与文本式 ImmersiveRoleplayView 不同：这里直接与语音大模型实时对话，
/// 后端只做转发，结束后由模型给出评分与分析。
struct ImmersiveVoiceLLMView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var realtime: RealtimeVoiceManager

    private enum Palette {
        static let top = Color(red: 0.07, green: 0.11, blue: 0.22)
        static let bottom = Color(red: 0.02, green: 0.03, blue: 0.08)
        static let user = Color(red: 0.12, green: 0.74, blue: 0.38)
        static let ai = Color(red: 0.32, green: 0.30, blue: 0.88)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.top, Palette.bottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                if isFinished {
                    reviewCard
                } else {
                    // 纯语音流对接：不做文字/语音转换，不显示字幕与指导，
                    // 界面中央只有一个跟随语音频率跳动的提示圈。
                    orb
                    statusLine
                    endButton
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
    }

    private var isFinished: Bool {
        if case .ended = realtime.phase { return true }
        if case .error = realtime.phase { return true }
        return false
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.scenario?.title ?? "实时语音对练")
                    .font(.system(size: 17 * model.fontScale, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("实时语音大模型 · 高级会员")
                    .font(.system(size: 12 * model.fontScale))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer()
            Button {
                if isFinished {
                    model.dismissVoiceLLM()
                } else {
                    model.endVoiceLLMPractice()
                }
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
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // 实时语音律动圆球：用户说话时绿色随电平跳动，AI 说话时紫色脉冲
    private var orb: some View {
        TimelineView(.animation) { timeline in
            ZStack {
                Circle()
                    .fill(orbColor)
                    .frame(width: 96, height: 96)
                    .scaleEffect(orbScale(at: timeline.date))
                    .shadow(color: orbColor.opacity(0.4), radius: 26, y: 8)
                if realtime.phase == .connecting || realtime.phase == .ending {
                    ProgressView().tint(.white).scaleEffect(1.2)
                } else {
                    Image(systemName: realtime.aiSpeaking ? "waveform" : "mic.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.top, 8)
    }

    private var orbColor: Color {
        if realtime.aiSpeaking { return Palette.ai }
        if realtime.inputLevel > 0.04 { return Palette.user }
        return Color.white.opacity(0.18)
    }

    private func orbScale(at date: Date) -> CGFloat {
        if realtime.aiSpeaking {
            let t = date.timeIntervalSinceReferenceDate
            return 1 + CGFloat(abs(sin(t * 6)) * 0.12)
        }
        return 1 + CGFloat(realtime.inputLevel) * 0.3
    }

    private var statusLine: some View {
        Text(realtime.statusText.isEmpty ? "请用英文开口说话" : realtime.statusText)
            .font(.system(size: 13 * model.fontScale, weight: .medium))
            .foregroundStyle(.white.opacity(0.62))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.top, 12)
    }

    private var endButton: some View {
        Button {
            model.endVoiceLLMPractice()
        } label: {
            Text("结束并评分")
                .font(.system(size: 15 * model.fontScale, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .overlay(Capsule().stroke(.white.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .disabled(realtime.phase == .ending || realtime.phase == .connecting)
        .padding(.top, 18)
    }

    private var reviewCard: some View {
        VStack(spacing: 16) {
            if let review = realtime.review {
                Text("\(review.score)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("本轮语音口语得分")
                    .font(.system(size: 13 * model.fontScale))
                    .foregroundStyle(.white.opacity(0.6))
                ScrollView {
                    Text(review.analysis.isEmpty ? "已完成本轮语音对练。" : review.analysis)
                        .font(.system(size: 15 * model.fontScale))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineSpacing(4)
                }
                .frame(maxHeight: 220)
            } else if case .error(let message) = realtime.phase {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 15 * model.fontScale))
                    .foregroundStyle(.white.opacity(0.88))
                    .multilineTextAlignment(.center)
            } else {
                Text(realtime.statusText.isEmpty ? "本轮已结束" : realtime.statusText)
                    .font(.system(size: 15 * model.fontScale))
                    .foregroundStyle(.white.opacity(0.88))
            }

            Button {
                model.dismissVoiceLLM()
            } label: {
                Text("完成")
                    .font(.system(size: 16 * model.fontScale, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(22)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.16)))
        .padding(.horizontal, 20)
    }
}
