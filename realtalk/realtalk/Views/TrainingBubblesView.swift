import SwiftUI

/// 训练系统：从界面下方向上弹出的「今日训练路径」透明气泡列表。
/// 对话过程中点右下角按钮唤起——课程编排引擎排好的场景（到期复习优先→新场景→已掌握），
/// 点任一气泡一键进入该场景训练。
struct TrainingBubblesOverlay: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            // 半透明遮罩：点空白处收起
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    model.trainingBubblesVisible = false
                } }

            VStack(alignment: .leading, spacing: 10) {
                header
                if model.trainingLoading && (model.trainingToday?.scenes.isEmpty ?? true) {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                } else if let scenes = model.trainingToday?.scenes, scenes.isEmpty == false {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(Array(scenes.enumerated()), id: \.element.id) { idx, scene in
                                bubble(scene, index: idx)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    .frame(maxHeight: 340)
                } else {
                    Text("今天还没有可训练的场景。先去生成或选一个场景练练吧。")
                        .font(.system(size: 14))
                        .foregroundStyle(RTTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 18)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(RTTheme.hairline, lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("今日训练")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(RTTheme.textPrimary)
            if let t = model.trainingToday {
                Text("约 \(t.minutesEstimate) 分钟 · 待复习 \(t.reviewsDue) · 已掌握 \(t.masteredTotal)")
                    .font(.system(size: 12))
                    .foregroundStyle(RTTheme.textSecondary)
            }
            Spacer()
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    model.trainingBubblesVisible = false
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RTTheme.textSecondary)
            }
        }
    }

    private func bubble(_ scene: TrainingSceneItem, index: Int) -> some View {
        Button {
            Task { await model.enterTrainingScene(scene) }
        } label: {
            HStack(spacing: 12) {
                statusDot(scene.status)
                VStack(alignment: .leading, spacing: 3) {
                    Text(scene.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(RTTheme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(statusLabel(scene.status))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(statusColor(scene.status))
                        if scene.reason.isEmpty == false {
                            Text("· \(scene.reason)")
                                .font(.system(size: 11))
                                .foregroundStyle(RTTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    if scene.scores.isEmpty == false, scene.status != "new" {
                        miniScores(scene.scores)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(RTTheme.accent)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RTTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func miniScores(_ scores: [String: Int]) -> some View {
        let dims: [(String, String)] = [("pronunciation", "音"), ("grammar", "法"),
                                        ("naturalness", "然"), ("vocabulary", "词")]
        return HStack(spacing: 8) {
            ForEach(dims, id: \.0) { key, label in
                let v = scores[key] ?? 0
                HStack(spacing: 2) {
                    Text(label).font(.system(size: 10)).foregroundStyle(RTTheme.textSecondary)
                    Text("\(v)").font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(dimColor(v))
                }
            }
        }
        .padding(.top, 1)
    }

    private func statusDot(_ status: String) -> some View {
        Circle().fill(statusColor(status)).frame(width: 10, height: 10)
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "mastered": return "已掌握"
        case "review": return "待复习"
        default: return "新场景"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "mastered": return RTTheme.success
        case "review": return .orange
        default: return RTTheme.accent
        }
    }

    private func dimColor(_ v: Int) -> Color {
        switch v {
        case 85...: return RTTheme.success
        case 70..<85: return RTTheme.accent
        case 50..<70: return .orange
        default: return .red
        }
    }
}
