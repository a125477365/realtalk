import SwiftUI

struct CaptureView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var speech: SpeechCaptureManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    capturePanel
                    TimeFilterPicker()
                    StatusBanner(text: combinedStatus)
                    transcriptList
                }
                .padding()
            }
            .navigationTitle("RealTalk")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.uploadPending() }
                    } label: {
                        Label("同步", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
    }

    private var capturePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Button {
                    Task { await model.toggleRecording() }
                } label: {
                    Label(
                        speech.isRecording ? "停止采集" : "开始采集",
                        systemImage: speech.isRecording ? "stop.circle.fill" : "mic.circle.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(speech.statusText)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("本地保留 \(AppConfig.localRetentionDays) 天")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if speech.partialText.isEmpty == false {
                Text(speech.partialText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.systemYellow).opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            Toggle(isOn: $model.autoCaptureEnabled) {
                Label("默认自动采集", systemImage: "calendar.badge.clock")
            }
            .onChange(of: model.autoCaptureEnabled) { _, _ in
                model.saveCaptureSchedule()
            }

            if model.autoCaptureEnabled {
                VStack(spacing: 10) {
                    DatePicker(
                        "开始时间",
                        selection: $model.autoCaptureStart,
                        displayedComponents: .hourAndMinute
                    )
                    .onChange(of: model.autoCaptureStart) { _, _ in
                        model.saveCaptureSchedule()
                    }

                    DatePicker(
                        "结束时间",
                        selection: $model.autoCaptureEnd,
                        displayedComponents: .hourAndMinute
                    )
                    .onChange(of: model.autoCaptureEnd) { _, _ in
                        model.saveCaptureSchedule()
                    }
                }
                .datePickerStyle(.compact)
                .font(.subheadline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("AirPods / 蓝牙麦克风优先", systemImage: "airpods")
                Label("只同步识别后的文字", systemImage: "text.bubble")
                Label("Siri 或系统打断时自动暂停", systemImage: "mic.slash")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var transcriptList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("对话片段")
                    .font(.headline)
                Spacer()
                Text("\(model.visibleSegments.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if model.visibleSegments.isEmpty {
                ContentUnavailableView("暂无片段", systemImage: "text.bubble")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(model.visibleSegments) { segment in
                        TranscriptRow(segment: segment)
                    }
                }
            }
        }
    }

    private var combinedStatus: String {
        [speech.lastError, model.statusMessage]
            .compactMap { $0 }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")
    }
}
