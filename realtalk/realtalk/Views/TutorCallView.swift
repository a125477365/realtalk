import Combine
import SwiftUI

/// 私教模式（电话按钮进入）：老师面对面——头像随说话动嘴、字幕/翻译开关、
/// 右上角切换 沉浸式(自动发送)/常规式(点击说话)，断线显示「重连」。
/// 与主界面共享同一条对话流与消息（进出私教不断线、上下文连续）；实时翻译也在本界面（mode=translate）。
struct TutorCallView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var stream: RoleplayStreamManager

    @State private var elapsed = 0
    @State private var showSubtitles = true
    @State private var showTranslation = true
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // 上浅下深的通话式背景
            LinearGradient(colors: [Color(red: 0.93, green: 0.93, blue: 0.95),
                                    Color(red: 0.13, green: 0.12, blue: 0.16)],
                           startPoint: .top, endPoint: .init(x: 0.5, y: 0.62))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                avatar
                    .padding(.top, 6)
                subtitleControls
                if showSubtitles { subtitles }
                Spacer()
                statusLine
                bottomControls
                Text("内容由 AI 生成")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.bottom, 8)
            }
        }
        .onAppear { model.startTutor() }
        .onReceive(timer) { _ in if model.homeConnected { elapsed += 1 } }
    }

    // MARK: 顶栏：退出 + 沉浸/常规切换

    private var topBar: some View {
        HStack {
            Button {
                model.closeTutor()
                dismiss()
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(red: 0.35, green: 0.35, blue: 0.4))
                    .frame(width: 46, height: 46)
                    .background(.white.opacity(0.75), in: Circle())
            }
            Spacer()
            if model.tutorMode == "translate" {
                Text("实时翻译")
                    .font(.system(size: 13 * model.fontScale, weight: .semibold))
                    .foregroundStyle(RTTheme.accent)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.75), in: Capsule())
            }
            // 音色选择：不同声音（性别/口音）随选随换，选择后按当前形态重连即刻生效
            if model.ttsVoices.isEmpty == false {
                Menu {
                    ForEach(model.ttsVoices, id: \.self) { v in
                        Button {
                            model.changeTutorVoice(v)
                        } label: {
                            if v == model.ttsCurrentVoice {
                                Label(v, systemImage: "checkmark")
                            } else {
                                Text(v)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "waveform.and.person.filled")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(RTTheme.accent)
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.75), in: Circle())
                }
                .padding(.trailing, 8)
            }
            Button { model.toggleTutorImmersive() } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.tutorImmersive ? "eye" : "waveform")
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.tutorImmersive ? "切为常规" : "切为沉浸")
                        .font(.system(size: 14 * model.fontScale, weight: .semibold))
                }
                .foregroundStyle(RTTheme.success)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.white.opacity(0.75), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: 老师头像（说话动嘴 + 聆听时轻微呼吸）

    private var avatar: some View {
        TutorAvatarFace(mouthOpen: stream.isAISpeaking ? stream.aiAudioLevel : 0,
                        listening: stream.isAISpeaking == false && model.homeConnected)
            .frame(width: 230, height: 230)
            .accessibilityLabel("AI 老师头像")
    }

    // MARK: 字幕区（计时 + 字幕/翻译开关 + 最近字幕）

    private var subtitleControls: some View {
        HStack {
            HStack(spacing: 5) {
                Circle().fill(model.homeConnected ? RTTheme.success : .red).frame(width: 7, height: 7)
                Text(timeString)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.black.opacity(0.35), in: Capsule())
            Spacer()
            controlToggle(icon: "captions.bubble", active: showSubtitles) { showSubtitles.toggle() }
            controlToggle(icon: "character.book.closed.zh", active: showTranslation) { showTranslation.toggle() }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
    }

    private func controlToggle(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(active ? .white : .white.opacity(0.4))
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.35), in: Circle())
                .overlay(alignment: .bottomTrailing) {
                    if active == false {
                        Image(systemName: "line.diagonal")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
        }
    }

    private var subtitles: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(recentLines) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(item.kind == .user ? RTTheme.accent : RTTheme.success)
                            .frame(width: 7, height: 7)
                            .padding(.top, 7)
                        Text(item.text)
                            .font(.system(size: 17 * model.fontScale, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    if showTranslation, item.translation.isEmpty == false {
                        Text(item.translation)
                            .font(.system(size: 14 * model.fontScale))
                            .foregroundStyle(.white.opacity(0.65))
                            .padding(.leading, 15)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .animation(.easeOut(duration: 0.2), value: model.homeItems.count)
    }

    /// 私教字幕只滚最近两条主对话（user/ai），指导与提示卡不在头像界面展示。
    private var recentLines: [AppModel.HomeChatItem] {
        Array(model.homeItems.filter { $0.kind == .user || $0.kind == .ai }.suffix(2))
    }

    private var timeString: String {
        String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    // MARK: 状态 + 底部控制

    private var statusLine: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle().fill(RTTheme.success.opacity(1 - Double(i) * 0.3)).frame(width: 7, height: 7)
            }
            Text(statusText)
                .font(.system(size: 14 * model.fontScale))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }

    private var statusText: String {
        if model.homeConnected == false { return "已断开" }
        if model.homeWorking { return model.tutorMode == "translate" ? "正在翻译…" : "老师正在思考…" }
        if stream.isAISpeaking { return "老师正在说话，开口即可打断" }
        if stream.manualRecording { return "正在录音，说完点发送" }
        return model.tutorImmersive ? "倾听中" : "点击下方按钮说话"
    }

    @ViewBuilder
    private var bottomControls: some View {
        if model.homeConnected == false {
            // 断线：点击重连（与参考交互一致）
            Button { model.reconnectTutor() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("重连")
                }
                .font(.system(size: 17 * model.fontScale, weight: .semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 44).padding(.vertical, 14)
                .background(.white, in: Capsule())
            }
            .padding(.bottom, 18)
        } else if model.tutorImmersive {
            // 沉浸式：自动 VAD——展示音量波形，无需操作
            HStack(spacing: 3) {
                ForEach(0..<9) { i in
                    Capsule()
                        .fill(RTTheme.success)
                        .frame(width: 4, height: 8 + CGFloat(((i * 7) % 9)) * 2.4 * (0.35 + 1.3 * stream.audioLevel))
                }
                Text(String(format: " %02d:%02d", elapsed / 60, elapsed % 60))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(height: 46)
            .padding(.horizontal, 34)
            .background(.white.opacity(0.12), in: Capsule())
            .animation(.easeOut(duration: 0.12), value: stream.audioLevel)
            .padding(.bottom, 18)
        } else {
            // 常规式：点击说话 / 说完发送
            Button {
                if stream.manualRecording { stream.endManualUtterance() } else { stream.beginManualUtterance() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: stream.manualRecording ? "stop.fill" : "wave.3.right")
                    Text(stream.manualRecording ? "说完了，发送" : "点击说话")
                }
                .font(.system(size: 18 * model.fontScale, weight: .semibold))
                .foregroundStyle(stream.manualRecording ? .white : Color(red: 0.2, green: 0.25, blue: 0.1))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(stream.manualRecording ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color(red: 0.85, green: 0.95, blue: 0.55)), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 40)
            .padding(.bottom, 18)
        }
    }
}

/// 微笑弧：一条向上开口的二次贝塞尔曲线（嘴角上扬）。
private struct SmileArc: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.midX, y: rect.maxY * 2))
        return p
    }
}

/// 中性机器人助教头像（无性别——男女音色都不违和）：金属渐变头壳 + 天线 + 屏幕脸 +
/// 发光眼(眨) + 嘴=说话时随电平跳动的音量条 / 聆听时发光微笑弧。可整体替换为品牌吉祥物素材。
struct TutorAvatarFace: View {
    var mouthOpen: Double       // 0~1，随 TTS 播放电平
    var listening: Bool
    @State private var blink = false
    @State private var breathe = false

    private let glow = Color(red: 0.35, green: 0.95, blue: 0.90)   // 荧光青（中性）

    var body: some View {
        VStack(spacing: 0) {
            // 天线：说话时顶灯亮
            Circle()
                .fill(mouthOpen > 0.02 ? glow : glow.opacity(0.35))
                .frame(width: 14, height: 14)
                .shadow(color: glow.opacity(mouthOpen > 0.02 ? 0.9 : 0.2), radius: 8)
            Rectangle()
                .fill(Color(red: 0.55, green: 0.60, blue: 0.68))
                .frame(width: 5, height: 18)

            ZStack {
                // 头壳
                RoundedRectangle(cornerRadius: 46)
                    .fill(LinearGradient(colors: [Color(red: 0.82, green: 0.86, blue: 0.92),
                                                  Color(red: 0.60, green: 0.66, blue: 0.76)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 200, height: 168)
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                // 耳侧
                HStack(spacing: 212) {
                    Capsule().fill(Color(red: 0.5, green: 0.55, blue: 0.64)).frame(width: 12, height: 44)
                    Capsule().fill(Color(red: 0.5, green: 0.55, blue: 0.64)).frame(width: 12, height: 44)
                }
                // 屏幕脸
                RoundedRectangle(cornerRadius: 32)
                    .fill(Color(red: 0.10, green: 0.12, blue: 0.18))
                    .frame(width: 164, height: 132)
                // 眼睛（发光、眨）
                HStack(spacing: 52) {
                    eye
                    eye
                }
                .offset(y: -22)
                // 嘴：说话=音量条；聆听=发光微笑
                mouth
                    .offset(y: 34)
            }
        }
        .scaleEffect(breathe && listening ? 1.015 : 1.0)
        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: breathe)
        .onAppear {
            breathe = true
            Timer.scheduledTimer(withTimeInterval: 3.2, repeats: true) { _ in
                Task { @MainActor in
                    blink = true
                    try? await Task.sleep(nanoseconds: 140_000_000)
                    blink = false
                }
            }
        }
    }

    private var eye: some View {
        Capsule()
            .fill(glow)
            .frame(width: 24, height: blink ? 4 : 26)
            .shadow(color: glow.opacity(0.8), radius: 6)
            .animation(.easeOut(duration: 0.1), value: blink)
    }

    @ViewBuilder
    private var mouth: some View {
        if mouthOpen > 0.02 {
            // 说话：三根音量条随电平跳动（机器人式"动嘴"）
            HStack(spacing: 7) {
                ForEach(0..<3) { i in
                    Capsule()
                        .fill(glow)
                        .frame(width: 9, height: 8 + CGFloat([0.7, 1.0, 0.8][i]) * 26 * min(1.0, mouthOpen * 1.6))
                        .shadow(color: glow.opacity(0.7), radius: 4)
                }
            }
            .animation(.easeOut(duration: 0.08), value: mouthOpen)
        } else {
            // 聆听：发光微笑弧
            SmileArc()
                .stroke(glow, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .frame(width: 52, height: 16)
                .shadow(color: glow.opacity(0.6), radius: 4)
        }
    }
}
