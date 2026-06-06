import SwiftUI

struct LearningView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TimeFilterPicker()

                    Button {
                        Task { await model.generateLearning() }
                    } label: {
                        Label(model.isWorking ? "生成中" : "生成学习内容", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isWorking)

                    StatusBanner(text: model.statusMessage)

                    if let learning = model.learning {
                        learningContent(learning)
                    } else {
                        ContentUnavailableView("选择时间范围后生成", systemImage: "book.closed")
                    }
                }
                .padding()
            }
            .navigationTitle("时间切片学习")
        }
    }

    @ViewBuilder
    private func learningContent(_ learning: LearningResponse) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(learning.summary)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

            sectionTitle("双语对照")
            ForEach(learning.dialogue) { line in
                VStack(alignment: .leading, spacing: 8) {
                    Text(line.role)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Text(line.zh)
                    Text(line.en)
                        .font(.headline)
                        .foregroundStyle(.blue)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }

            sectionTitle("高频表达")
            ForEach(learning.expressions) { expression in
                VStack(alignment: .leading, spacing: 7) {
                    Text(expression.phrase)
                        .font(.headline)
                    Text(expression.meaning)
                        .foregroundStyle(.secondary)
                    Text(expression.example)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }

            sectionTitle("练习句")
            ForEach(learning.drills) { drill in
                VStack(alignment: .leading, spacing: 8) {
                    Text(drill.prompt)
                        .font(.body)
                    Text(drill.answer)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}
