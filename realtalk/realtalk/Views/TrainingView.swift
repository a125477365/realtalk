import SwiftUI

struct TrainingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TimeFilterPicker()

                    Button {
                        Task { await model.startTraining() }
                    } label: {
                        Label("开始强约束训练", systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isWorking)

                    StatusBanner(text: model.statusMessage)

                    if let training = model.training {
                        trainingPanel(training)
                    } else {
                        ContentUnavailableView("暂无训练", systemImage: "checkmark.bubble")
                    }
                }
                .padding()
            }
            .navigationTitle("逐句训练")
        }
    }

    private func trainingPanel(_ training: TrainingStateResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("第 \(min(training.index + 1, max(training.total, 1))) / \(training.total) 句")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: training.completed ? "checkmark.seal.fill" : "lock.fill")
                    .foregroundStyle(training.completed ? .green : .secondary)
            }

            if training.completed {
                ContentUnavailableView("训练完成", systemImage: "checkmark.seal")
            } else {
                Text(training.prompt)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

                TextEditor(text: $model.trainingAnswer)
                    .frame(minHeight: 110)
                    .padding(8)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

                Button {
                    Task { await model.submitTrainingAnswer() }
                } label: {
                    Label("提交本句", systemImage: "paperplane")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking || model.trainingAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let feedback = training.feedback, feedback.isEmpty == false {
                VStack(alignment: .leading, spacing: 8) {
                    Label("判定", systemImage: "checkmark.circle")
                        .font(.headline)
                    Text(feedback)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }

            if let correction = training.correction, correction.isEmpty == false {
                VStack(alignment: .leading, spacing: 8) {
                    Label("纠错", systemImage: "pencil.and.scribble")
                        .font(.headline)
                    Text(correction)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
