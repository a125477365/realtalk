import SwiftUI

/// 学习提醒「私教来电」：仿即时通讯来电界面。
/// 响铃 → 接听后私教语音询问是否现在练习新场景；「现在练习」走与点场景卡相同的流程，
/// 「暂不/挂断」后该场景不再来电（后端幂等记录）。
struct ReminderCallView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var voice: VoicePromptPlayer
    let scenario: ScenarioSummary

    @State private var answered = false
    @State private var pulsing = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.09, blue: 0.07), Color(red: 0.03, green: 0.05, blue: 0.10)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer().frame(height: 60)
                ZStack {
                    Circle()
                        .fill(RTTheme.success.opacity(0.22))
                        .frame(width: 148, height: 148)
                        .scaleEffect(pulsing ? 1.18 : 1)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulsing)
                    Circle().fill(RTTheme.brandGradient).frame(width: 116, height: 116)
                    Image(systemName: "graduationcap.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("AI英语私教")
                    .font(.system(size: 24 * model.fontScale, weight: .semibold))
                    .foregroundStyle(.white)
                Text(answered ? "有一个新场景还没练习：" : "邀请你练习新场景…")
                    .font(.system(size: 14 * model.fontScale))
                    .foregroundStyle(.white.opacity(0.6))
                Text("《\(scenario.title)》")
                    .font(.system(size: 18 * model.fontScale, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

                Spacer()

                if answered {
                    answeredButtons
                } else {
                    ringingButtons
                }
                Spacer().frame(height: 56)
            }
        }
        .onAppear { pulsing = true }
    }

    private var ringingButtons: some View {
        HStack(spacing: 88) {
            VStack(spacing: 8) {
                Button {
                    voice.stop()
                    model.declineReminder()
                } label: {
                    ZStack {
                        Circle().fill(Color(red: 0.88, green: 0.18, blue: 0.18)).frame(width: 72, height: 72)
                        Image(systemName: "phone.down.fill").font(.system(size: 28)).foregroundStyle(.white)
                    }
                }
                Text("挂断").font(.system(size: 13 * model.fontScale)).foregroundStyle(.white.opacity(0.6))
            }
            VStack(spacing: 8) {
                Button {
                    answered = true
                    // 接听后私教语音询问（动态内容不入缓存）
                    voice.speak("Hi! 我看到你有一个新的场景《\(scenario.title)》还没练习，现在有时间练一练吗？", cache: false)
                } label: {
                    ZStack {
                        Circle().fill(RTTheme.success).frame(width: 72, height: 72)
                        Image(systemName: "phone.fill").font(.system(size: 28)).foregroundStyle(.white)
                    }
                }
                Text("接听").font(.system(size: 13 * model.fontScale)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var answeredButtons: some View {
        VStack(spacing: 14) {
            Button {
                voice.stop()
                model.acceptReminder()
            } label: {
                Text("现在练习")
                    .font(.system(size: 17 * model.fontScale, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(RTTheme.success, in: RoundedRectangle(cornerRadius: 16))
            }
            Button {
                voice.stop()
                model.declineReminder()
            } label: {
                Text("暂不练习（之后手动进入）")
                    .font(.system(size: 15 * model.fontScale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding(.horizontal, 44)
    }
}
