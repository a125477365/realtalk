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
