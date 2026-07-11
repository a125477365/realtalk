import SwiftUI
import UIKit

/// 详细指导浮层：发音逐词分析（词级置信度标色）+ 评分/语速建议 + 语境润色（三风格）。
/// 数据来源：词级详情随字幕实时下发（本地语音服务器 whisper 词级置信度）；润色按需调后端一次。
struct GuidanceDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: AppModel.HomeChatItem

    @State private var refinements: [RefineItem] = []
    @State private var refineStyle = "地道美式"
    @State private var refineLoading = false
    @State private var refineError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    wordAnalysis
                    scoreSection
                    refineSection
                    Text("内容由 AI 生成")
                        .font(.system(size: 11))
                        .foregroundStyle(RTTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(16)
            }
            .background(RTTheme.background)
            .navigationTitle("发音逐词分析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)) }
                }
            }
            .task { await loadRefinements() }
        }
    }

    // MARK: 发音逐词分析（标色）

    private var wordAnalysis: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                legend("待提高", .red)
                legend("小瑕疵", .orange)
                legend("很完美", RTTheme.textPrimary)
            }
            .font(.system(size: 11 * model.fontScale))
            WrappingWords(words: item.words, fontScale: model.fontScale)
            HStack(spacing: 18) {
                Button { model.speakText(item.text) } label: {
                    Label("AI 朗读", systemImage: "speaker.wave.2").font(.system(size: 13, weight: .medium))
                }
                Button { UIPasteboard.general.string = item.text } label: {
                    Label("复制", systemImage: "doc.on.doc").font(.system(size: 13, weight: .medium))
                }
                Spacer()
            }
            .foregroundStyle(RTTheme.accent)
        }
        .padding(14)
        .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(RTTheme.textSecondary)
        }
    }

    // MARK: 评分建议

    private var overall: Int {
        guard item.words.isEmpty == false else { return 0 }
        let avg = item.words.map(\.probability).reduce(0, +) / Double(item.words.count)
        return Int((avg * 100).rounded())
    }

    private var scoreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("评分建议").font(.system(size: 16 * model.fontScale, weight: .semibold)).foregroundStyle(RTTheme.textPrimary)
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(RTTheme.hairline, lineWidth: 6)
                    Circle().trim(from: 0, to: CGFloat(overall) / 100)
                        .stroke(overall >= 80 ? RTTheme.success : .orange, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(overall)").font(.system(size: 20, weight: .bold)).foregroundStyle(RTTheme.textPrimary)
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 6) {
                    scoreRow("发音分", overall)
                    if item.wpm > 0 {
                        HStack(spacing: 8) {
                            Text("语速").font(.system(size: 13 * model.fontScale)).foregroundStyle(RTTheme.textSecondary)
                            Text("\(item.wpm) 词/分").font(.system(size: 13 * model.fontScale, weight: .semibold))
                                .foregroundStyle(item.wpm < 90 ? .orange : (item.wpm > 200 ? .red : RTTheme.success))
                        }
                    }
                }
                Spacer()
            }
            Text(advice)
                .font(.system(size: 13 * model.fontScale))
                .foregroundStyle(RTTheme.textSecondary)
        }
        .padding(14)
        .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func scoreRow(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 13 * model.fontScale)).foregroundStyle(RTTheme.textSecondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(RTTheme.hairline)
                    Capsule().fill(value >= 80 ? RTTheme.success : .orange)
                        .frame(width: geo.size.width * CGFloat(value) / 100)
                }
            }
            .frame(width: 110, height: 6)
            Text("\(value)").font(.system(size: 13 * model.fontScale, weight: .semibold)).foregroundStyle(RTTheme.textPrimary)
        }
    }

    private var advice: String {
        var parts: [String] = []
        if overall >= 85 { parts.append("发音纯正，继续保持。") }
        else if overall >= 65 { parts.append("发音总体不错，标红的词再跟读几遍。") }
        else if overall > 0 { parts.append("多听 AI 朗读，逐词跟读标红的部分。") }
        if item.wpm > 0 {
            if item.wpm < 90 { parts.append("语速偏慢，说快一点听起来更自然。") }
            else if item.wpm > 200 { parts.append("语速偏快，适当放慢更清晰。") }
            else { parts.append("语速合适。") }
        }
        return parts.joined(separator: " ")
    }

    // MARK: 语境润色

    private var refineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("语境润色").font(.system(size: 16 * model.fontScale, weight: .semibold)).foregroundStyle(RTTheme.textPrimary)
            if refineLoading {
                HStack { ProgressView(); Text("正在润色…").font(.system(size: 13)).foregroundStyle(RTTheme.textSecondary) }
            } else if let err = refineError {
                Text(err).font(.system(size: 13)).foregroundStyle(.red)
            } else if refinements.isEmpty == false {
                HStack(spacing: 0) {
                    ForEach(refinements) { r in
                        Button { refineStyle = r.style } label: {
                            Text(r.style)
                                .font(.system(size: 14 * model.fontScale, weight: refineStyle == r.style ? .semibold : .regular))
                                .foregroundStyle(refineStyle == r.style ? RTTheme.success : RTTheme.textSecondary)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .overlay(alignment: .bottom) {
                                    if refineStyle == r.style { Capsule().fill(RTTheme.success).frame(height: 2) }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let current = refinements.first(where: { $0.style == refineStyle }) {
                    Text("优化后的句子：\(current.text)")
                        .font(.system(size: 14 * model.fontScale))
                        .foregroundStyle(RTTheme.textPrimary)
                    HStack(spacing: 18) {
                        Button { model.speakText(current.text) } label: {
                            Label("AI 朗读", systemImage: "speaker.wave.2").font(.system(size: 13, weight: .medium))
                        }
                        Button { UIPasteboard.general.string = current.text } label: {
                            Label("复制", systemImage: "doc.on.doc").font(.system(size: 13, weight: .medium))
                        }
                        Spacer()
                    }
                    .foregroundStyle(RTTheme.accent)
                }
            }
        }
        .padding(14)
        .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func loadRefinements() async {
        guard refinements.isEmpty, refineLoading == false else { return }
        refineLoading = true
        defer { refineLoading = false }
        do {
            refinements = try await model.refineText(item.text)
        } catch {
            refineError = "润色失败：\(error.localizedDescription)"
        }
    }
}

/// 逐词标色流式排版：按置信度着色（<0.6 红 / <0.85 橙 / 其余正文色）。
private struct WrappingWords: View {
    let words: [RoleplayStreamManager.WordScore]
    let fontScale: Double

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, w in
                Text(w.word)
                    .font(.system(size: 17 * fontScale, weight: .medium))
                    .foregroundStyle(color(for: w.probability))
            }
        }
    }

    private func color(for p: Double) -> Color {
        if p < 0.6 { return .red }
        if p < 0.85 { return .orange }
        return RTTheme.textPrimary
    }
}

/// 简单的流式布局（词按行自动换行）。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
