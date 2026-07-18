import SwiftUI

struct DreamyBackdrop: View {
    @State private var drift = false

    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.16, green: 0.56, blue: 0.96),
                Color(red: 0.10, green: 0.78, blue: 0.70),
                Color(red: 0.96, green: 0.56, blue: 0.72),
                Color(red: 1.00, green: 0.78, blue: 0.42),
            ],
            startPoint: drift ? .topTrailing : .topLeading,
            endPoint: drift ? .bottomLeading : .bottomTrailing
        )
        .overlay {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    for index in 0..<6 {
                        var path = Path()
                        let base = size.height * (0.18 + CGFloat(index) * 0.13)
                        path.move(to: CGPoint(x: 0, y: base))
                        for step in stride(from: 0, through: Int(size.width), by: 12) {
                            let x = CGFloat(step)
                            let y = base + sin((x / 54) + time + Double(index)) * 18
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        context.stroke(
                            path,
                            with: .color(.white.opacity(index.isMultiple(of: 2) ? 0.15 : 0.09)),
                            lineWidth: 1.4
                        )
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                drift.toggle()
            }
        }
    }
}

struct VoicePulseGlyph: View {
    let isActive: Bool
    var tint: Color = .blue

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint.opacity(index == 2 ? 1 : 0.78))
                        .frame(width: 5, height: barHeight(index: index, time: time))
                }
            }
            .frame(width: 42, height: 42)
            .padding(12)
            .background(tint.opacity(0.16), in: Circle())
            .overlay {
                Circle()
                    .stroke(tint.opacity(isActive ? 0.32 : 0.16), lineWidth: 1)
            }
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        guard isActive else { return CGFloat([14, 22, 30, 22, 14][index]) }
        let wave = sin(time * 5 + Double(index) * 0.78)
        return 16 + CGFloat(wave + 1) * 13
    }
}

/// 品牌渐变底色的分段选择器（替代灰底的原生 segmented control）：
/// 整条背景为「开始采集」同款渐变，选中项为白色胶囊。
struct BrandSegmentedPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]
    var fontScale: Double = 1.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = selection == option.value
                Text(option.label)
                    .font(.system(size: 14 * fontScale, weight: .semibold))
                    .foregroundStyle(isSelected ? RTTheme.accent : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.clear), in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.18)) { selection = option.value }
                    }
            }
        }
        .padding(4)
        .background(RTTheme.brandGradient, in: Capsule())
    }
}

struct TimeFilterPicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("范围", selection: $model.filter) {
                ForEach(TranscriptStore.TimeFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            if model.filter == .custom {
                VStack(spacing: 10) {
                    DatePicker("开始", selection: $model.customStart)
                    DatePicker("结束", selection: $model.customEnd)
                }
                .datePickerStyle(.compact)
                .font(.system(size: 15 * model.fontScale))
            }
        }
    }
}

struct StatusBanner: View {
    @EnvironmentObject private var model: AppModel
    let text: String

    var body: some View {
        if text.isEmpty == false {
            Text(text)
                .font(.system(size: 13 * model.fontScale))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct TranscriptRow: View {
    @EnvironmentObject private var model: AppModel
    let segment: TranscriptSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(segment.shortTime)
                    .font(.system(size: 12 * model.fontScale, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Image(systemName: segment.uploadedAt == nil ? "icloud.and.arrow.up" : "checkmark.icloud")
                    .font(.caption)
                    .foregroundStyle(segment.uploadedAt == nil ? .orange : .green)
                    .accessibilityLabel(segment.uploadedAt == nil ? "未同步" : "已同步")
            }

            Text(segment.text)
                .font(.system(size: 17 * model.fontScale))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: 音色 / 语速 底部子面板（私教 + 主界面「+」共用）

/// 音色元数据（性别 + 支持语言）——与后端 voice_io.VOICE_META 保持一致，用于 UI 分组与标签。
/// 后端负责「所选英文音色遇到中文自动换同性别中文音色」；这里只做展示。
enum VoiceInfo {
    struct Meta { let gender: String; let langs: [String]; let gentle: Bool }
    static let table: [String: Meta] = [
        "Vivian": .init(gender: "female", langs: ["zh", "en"], gentle: true),
        "Serena": .init(gender: "female", langs: ["zh", "en"], gentle: true),
        "Ono_Anna": .init(gender: "female", langs: ["zh", "en"], gentle: false),
        "Sohee": .init(gender: "female", langs: ["zh", "en"], gentle: false),
        "Aiden": .init(gender: "male", langs: ["zh", "en"], gentle: false),
        "Dylan": .init(gender: "male", langs: ["zh", "en"], gentle: false),
        "Eric": .init(gender: "male", langs: ["zh", "en"], gentle: false),
        "Ryan": .init(gender: "male", langs: ["zh", "en"], gentle: false),
        "Uncle_Fu": .init(gender: "male", langs: ["zh", "en"], gentle: false),
        "coral": .init(gender: "female", langs: ["en"], gentle: false),
        "shimmer": .init(gender: "female", langs: ["en"], gentle: false),
        "sage": .init(gender: "female", langs: ["en"], gentle: false),
        "marin": .init(gender: "female", langs: ["en"], gentle: false),
        "alloy": .init(gender: "male", langs: ["en"], gentle: false),
        "ash": .init(gender: "male", langs: ["en"], gentle: false),
        "ballad": .init(gender: "male", langs: ["en"], gentle: false),
        "echo": .init(gender: "male", langs: ["en"], gentle: false),
        "verse": .init(gender: "male", langs: ["en"], gentle: false),
        "cedar": .init(gender: "male", langs: ["en"], gentle: false),
    ]
    static func meta(_ v: String) -> Meta { table[v] ?? .init(gender: "female", langs: ["zh", "en"], gentle: false) }
    static func isFemale(_ v: String) -> Bool { meta(v).gender == "female" }
    static func langBadge(_ v: String) -> String {
        let l = meta(v).langs
        if l.contains("zh") && l.contains("en") { return "中英" }
        if l.contains("zh") { return "中" }
        return "英"
    }
}

/// 语速 + 音色选择底部子面板。私教底部「音色」按钮、主界面「+」里都用它。
struct VoiceSpeedSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// (显示名, 倍速值)
    private let speeds: [(String, Double)] = [("正常", 1.0), ("慢 0.5×", 0.5), ("快 1.5×", 1.5), ("快 2×", 2.0)]

    private var femaleVoices: [String] { model.ttsVoices.filter { VoiceInfo.isFemale($0) } }
    private var maleVoices: [String] { model.ttsVoices.filter { VoiceInfo.isFemale($0) == false } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    speedSection
                    if femaleVoices.isEmpty == false { voiceSection("女声", femaleVoices) }
                    if maleVoices.isEmpty == false { voiceSection("男声", maleVoices) }
                    Text("说明：中文讲解会自动用同性别的中文音色朗读；选到「中英」音色则一直用它。语速为本机播放倍速。")
                        .font(.system(size: 12 * model.fontScale))
                        .foregroundStyle(RTTheme.textSecondary)
                        .padding(.top, 4)
                }
                .padding(20)
            }
            .navigationTitle("语音设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("语速").font(.system(size: 15 * model.fontScale, weight: .semibold)).foregroundStyle(RTTheme.textPrimary)
            HStack(spacing: 8) {
                ForEach(speeds, id: \.1) { name, value in
                    let selected = abs(model.playbackSpeed - value) < 0.01
                    Button { model.playbackSpeed = value } label: {
                        Text(name)
                            .font(.system(size: 13 * model.fontScale, weight: .medium))
                            .foregroundStyle(selected ? .white : RTTheme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(selected ? RTTheme.accent : RTTheme.hairline,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func voiceSection(_ title: String, _ voices: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 音色 · \(title)").font(.system(size: 15 * model.fontScale, weight: .semibold)).foregroundStyle(RTTheme.textPrimary)
            VStack(spacing: 0) {
                ForEach(voices, id: \.self) { v in
                    let selected = v == model.ttsCurrentVoice
                    Button { model.changeTutorVoice(v) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: VoiceInfo.isFemale(v) ? "person.fill" : "person")
                                .font(.system(size: 15))
                                .foregroundStyle(VoiceInfo.isFemale(v) ? Color.pink : Color.blue)
                            Text(v).font(.system(size: 15 * model.fontScale, weight: .medium)).foregroundStyle(RTTheme.textPrimary)
                            if VoiceInfo.meta(v).gentle {
                                Text("温柔").font(.system(size: 10)).foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(RTTheme.success, in: Capsule())
                            }
                            Text(VoiceInfo.langBadge(v)).font(.system(size: 10))
                                .foregroundStyle(RTTheme.textSecondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .overlay(Capsule().stroke(RTTheme.hairline, lineWidth: 1))
                            Spacer()
                            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(RTTheme.accent) }
                        }
                        .padding(.vertical, 11).padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if v != voices.last { Divider() }
                }
            }
            .padding(.horizontal, 12)
            .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
