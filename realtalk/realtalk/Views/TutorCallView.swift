import AVFoundation
import Combine
import SwiftUI

/// 私教通话（顶栏电话按钮进入，全屏）：Claude 语音式界面——
/// 深色底 + 底部光晕随说话音量呼吸、老师头像动嘴、随声音变化的麦克风、
/// 底部一排：音色胶囊（中）+ 退出 X（右）。注重自由对话，不放多余选项。
/// 与主界面共享同一条对话流与消息（进出私教不断线、上下文连续）；实时翻译也在本界面（mode=translate）。
struct TutorCallView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var stream: RoleplayStreamManager

    @State private var elapsed = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// 当前活跃声音电平：用户说话取麦克风电平，老师说话取播放电平。
    private var liveLevel: Double {
        stream.isAISpeaking ? stream.aiAudioLevel : stream.audioLevel
    }

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.08, blue: 0.10).ignoresSafeArea()
            bottomGlow
            VStack(spacing: 0) {
                header
                // 头像固定在顶部：不随字幕滚动。字幕在其下方固定区域，剩余空间由下方 Spacer 吸收。
                avatar
                    .padding(.top, 6)
                statusLine
                    .padding(.top, 12)
                subtitles
                Spacer(minLength: 12)
                micIndicator
                    .padding(.bottom, 22)
                bottomBar
                Text("内容由 AI 生成")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            }
        }
        .onAppear { model.startTutor() }
        .onReceive(timer) { _ in if model.homeConnected { elapsed += 1 } }
    }

    /// 按当前所选音色判定老师性别（决定显示男/女 3D 人物）。
    private var tutorIsFemale: Bool { TutorAvatarView.isFemaleVoice(model.ttsCurrentVoice) }

    // MARK: 底部光晕：从底部升到屏幕中部，亮度/范围随说话频率呼吸（参考 Claude 语音界面）

    private var bottomGlow: some View {
        RadialGradient(
            colors: [
                Color(red: 0.25, green: 0.47, blue: 0.85).opacity(0.28 + 0.5 * liveLevel),
                Color(red: 0.16, green: 0.30, blue: 0.62).opacity(0.10 + 0.25 * liveLevel),
                .clear,
            ],
            center: UnitPoint(x: 0.5, y: 1.12),
            startRadius: 10,
            endRadius: 330 + 260 * liveLevel
        )
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.12), value: liveLevel)
        .allowsHitTesting(false)
    }

    // MARK: 顶部：计时 +（翻译模式标记）

    private var header: some View {
        HStack {
            HStack(spacing: 5) {
                Circle().fill(model.homeConnected ? RTTheme.success : .red).frame(width: 7, height: 7)
                Text(timeString)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.white.opacity(0.10), in: Capsule())
            Spacer()
            if model.tutorMode == "translate" {
                Text("实时翻译")
                    .font(.system(size: 13 * model.fontScale, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.white.opacity(0.10), in: Capsule())
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    // MARK: 老师头像（固定顶部；有 3D 人物素材则显示写实人像 + 说话发光，否则回退机器人脸）

    private var avatar: some View {
        TutorAvatarView(
            isFemale: tutorIsFemale,
            speaking: stream.isAISpeaking,
            level: stream.isAISpeaking ? stream.aiAudioLevel : 0,
            listening: stream.isAISpeaking == false && model.homeConnected
        )
        .accessibilityLabel(tutorIsFemale ? "AI 女老师头像" : "AI 男老师头像")
    }

    private var statusLine: some View {
        Text(statusText)
            .font(.system(size: 15 * model.fontScale, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var statusText: String {
        if model.homeConnected == false { return "连接断开了，点下方按钮重连" }
        if model.homeWorking { return model.tutorMode == "translate" ? "正在翻译…" : "老师正在思考…" }
        if stream.isAISpeaking { return "老师正在说话，开口即可打断" }
        if stream.manualRecording { return "正在录音，说完点麦克风发送" }
        // 后端的忙碌/重连/合成失败等提示必须让用户看到（此前永远显示「倾听中」，出错像没反应）
        if model.homeStatus.isEmpty == false { return model.homeStatus }
        return "倾听中，直接开口说英语"
    }

    // MARK: 字幕（最近两条 + 中文翻译）

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
                    if model.showChineseHint, item.translation.isEmpty == false {
                        Text(item.translation)
                            .font(.system(size: 14 * model.fontScale))
                            .foregroundStyle(.white.opacity(0.65))
                            .padding(.leading, 15)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
        .padding(.top, 14)
        .animation(.easeOut(duration: 0.2), value: model.homeItems.count)
    }

    /// 私教字幕只滚最近两条主对话（user/ai），指导与提示卡不在头像界面展示。
    private var recentLines: [AppModel.HomeChatItem] {
        Array(model.homeItems.filter { $0.kind == .user || $0.kind == .ai }.suffix(2))
    }

    private var timeString: String {
        String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    // MARK: 中央麦克风：随「用户/老师说话」的音量呼吸；断线时变成重连按钮

    @ViewBuilder
    private var micIndicator: some View {
        if model.homeConnected == false {
            Button { model.reconnectTutor() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("重连")
                }
                .font(.system(size: 17 * model.fontScale, weight: .semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 40).padding(.vertical, 15)
                .background(.white, in: Capsule())
            }
        } else {
            Button {
                // 手动形态点按开始/发送；沉浸形态点按＝暂停/恢复聆听
                if stream.manualRecording {
                    stream.endManualUtterance()
                } else if stream.manualCommit {
                    stream.beginManualUtterance()
                } else {
                    stream.togglePause()
                }
            } label: {
                ZStack {
                    // 外圈随音量扩散
                    Circle()
                        .stroke((stream.isAISpeaking ? RTTheme.success : RTTheme.accent).opacity(0.35 + 0.4 * liveLevel),
                                lineWidth: 2)
                        .frame(width: 96 + 34 * liveLevel, height: 96 + 34 * liveLevel)
                    Circle()
                        .fill(.white.opacity(0.10))
                        .frame(width: 84, height: 84)
                        .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                    Image(systemName: micSymbol)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white)
                        .scaleEffect(1 + 0.18 * liveLevel)
                }
                .animation(.easeOut(duration: 0.1), value: liveLevel)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(stream.isPaused ? "恢复聆听" : "麦克风")
        }
    }

    private var micSymbol: String {
        if stream.isPaused { return "mic.slash.fill" }
        if stream.manualRecording { return "arrow.up.circle.fill" }
        return "mic.fill"
    }

    // MARK: 底部一排：音色胶囊（中）+ 退出 X（右）

    private var bottomBar: some View {
        ZStack {
            // 音色选择：随选随换（入库后按当前形态重连即刻生效）
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
                HStack(spacing: 6) {
                    Text(model.ttsCurrentVoice.isEmpty ? "音色" : model.ttsCurrentVoice)
                        .font(.system(size: 16 * model.fontScale, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 22).padding(.vertical, 13)
                .background(.white.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
            }
            .disabled(model.ttsVoices.isEmpty)

            HStack {
                Spacer()
                Button { model.closeTutor() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color(red: 0.15, green: 0.16, blue: 0.19))
                        .frame(width: 56, height: 56)
                        .background(.white, in: Circle())
                }
                .accessibilityLabel("结束私教通话")
            }
        }
        .padding(.horizontal, 24)
    }
}

/// 私教老师头像（固定顶部）：优先用运营放入的写实 3D 人物素材，按当前音色性别选男/女；
/// 素材缺失时回退中性机器人脸（可动嘴）。
/// 素材放置方式（放入后自动生效、无需改代码）：
///   - 图片：在 Assets.xcassets 里新建图集，命名 `tutor_female` / `tutor_male`（3D 渲染 PNG，建议竖版透明底/白底）。
///     静态图无法跟语音动口型，改用「说话时头像发光 + 轻微缩放」表达"正在说话"。
///   - 视频：把 `tutor_female.mp4` / `tutor_male.mp4`（几秒说话循环）加入 App Bundle，AI 说话时循环播放、聆听时定帧
///     （如需口型动感走这条；接入见 VideoAvatarView 注释）。
struct TutorAvatarView: View {
    var isFemale: Bool
    var speaking: Bool
    var level: Double
    var listening: Bool
    @State private var breathe = false

    /// 女声音色集合（Qwen 本地 + OpenAI）；不在其中默认男声。
    private static let femaleVoices: Set<String> = [
        "vivian", "serena", "ono_anna", "sohee",         // Qwen 本地
        "coral", "shimmer", "sage", "marin",              // OpenAI
    ]
    static func isFemaleVoice(_ voice: String) -> Bool {
        femaleVoices.contains(voice.lowercased())
    }

    private var assetName: String { isFemale ? "tutor_female" : "tutor_male" }
    private var hasImage: Bool { UIImage(named: assetName) != nil }
    /// 说话循环视频（口型动感）：把 tutor_female.mp4 / tutor_male.mp4 拖进 realtalk/realtalk/ 目录即生效
    /// （工程是文件夹自动同步格式，无需改工程文件）。AI 说话时循环播放、安静时定帧；视频本身静音。
    private var videoURL: URL? { Bundle.main.url(forResource: assetName, withExtension: "mp4") }

    var body: some View {
        Group {
            if let url = videoURL {
                videoAvatar(url)
            } else if hasImage {
                photoAvatar
            } else {
                // 无写实素材：回退机器人脸（能动嘴，性别只影响荧光色调）
                TutorAvatarFace(mouthOpen: speaking ? level : 0, listening: listening)
                    .frame(width: 210, height: 210)
            }
        }
    }

    /// 视频人像：AI 说话时循环播放（有口型），聆听/静默时暂停定帧。
    private func videoAvatar(_ url: URL) -> some View {
        LoopingVideoView(url: url, playing: speaking)
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(
                // 底部渐隐到背景色，让字幕自然叠在人像下缘
                LinearGradient(colors: [.clear, .clear, Color(red: 0.07, green: 0.08, blue: 0.10)],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(RTTheme.success.opacity(speaking ? 0.25 + 0.5 * level : 0))
                    .frame(height: 3)
                    .blur(radius: 2)
            }
    }

    /// 写实 3D 人物：竖版铺满顶部 + 底部渐隐（与截图一致）；说话时描边发光并轻微放大表达"在说话"。
    private var photoAvatar: some View {
        Image(assetName)
            .resizable()
            .scaledToFill()
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(
                // 底部渐隐到背景色，让字幕自然叠在人像下缘
                LinearGradient(colors: [.clear, .clear, Color(red: 0.07, green: 0.08, blue: 0.10)],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(alignment: .bottom) {
                // 说话指示：底部一条随电平呼吸的发光（静态图没有口型，用它表达"正在说话"）
                Rectangle()
                    .fill(RTTheme.success.opacity(speaking ? 0.25 + 0.5 * level : 0))
                    .frame(height: 3)
                    .blur(radius: 2)
            }
            .scaleEffect(speaking ? 1.0 + 0.012 * level : (breathe && listening ? 1.006 : 1.0))
            .animation(.easeOut(duration: 0.12), value: level)
            .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: breathe)
            .onAppear { breathe = true }
    }
}

/// 无缝循环视频层（静音）：AVPlayerLooper 循环播放说话小视频；playing=false 时暂停定帧。
/// 声音永远来自后端 TTS，视频只提供口型画面，必须静音。
private struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    let playing: Bool

    final class PlayerContainerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        var url: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        attach(url, to: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: PlayerContainerView, context: Context) {
        if context.coordinator.url != url {   // 切换音色性别 → 换视频
            attach(url, to: view, coordinator: context.coordinator)
        }
        if playing {
            context.coordinator.player?.play()
        } else {
            context.coordinator.player?.pause()
        }
    }

    private func attach(_ url: URL, to view: PlayerContainerView, coordinator: Coordinator) {
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        coordinator.player = player
        coordinator.url = url
        view.playerLayer.player = player
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
