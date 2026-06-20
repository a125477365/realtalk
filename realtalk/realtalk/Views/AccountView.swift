import SwiftUI
import UniformTypeIdentifiers

struct AccountView: View {
    var body: some View {
        AccountPanelView()
    }
}

/// 账户面板：会员状态 / token 用量 / 套餐购买 / 充值 / 录音上传 / 账单 / 设置入口
struct AccountPanelView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingSettings = false
    @State private var showingUpload = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    memberCard
                    uploadEntry
                    ledger
                    StatusBanner(text: model.statusMessage)
                }
                .padding(16)
            }
            .background(RTTheme.background)
            .navigationTitle("账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingUpload) { UploadRecordingView() }
            .task {
                await model.loadBillingAccount()
                if model.planCatalog.isEmpty { await model.loadPlanCatalog() }
            }
        }
    }

    // MARK: 会员卡

    private var memberCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(.white.opacity(0.25))
                    Text((auth.user?.displayName ?? "我").prefix(1))
                        .font(.system(size: 20 * model.fontScale, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(auth.user?.displayName ?? "微信用户")
                            .font(.system(size: 17 * model.fontScale, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(auth.user?.tierName ?? "免费用户")
                            .font(.system(size: 11 * model.fontScale, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.22), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    if let expires = auth.user?.planExpiresAt {
                        Text("有效期至 \(expires.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 12 * model.fontScale))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(money(auth.user?.balanceCents ?? 0))
                        .font(.system(size: 20 * model.fontScale, weight: .bold))
                        .foregroundStyle(.white)
                    Text("余额")
                        .font(.system(size: 11 * model.fontScale))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }

            if let usage = model.billingAccount?.usage {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("本月 AI 费用额度")
                            .font(.system(size: 12 * model.fontScale))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Text(String(format: "¥%.2f / ¥%.2f", usage.monthCostYuan, usage.monthBudgetYuan))
                            .font(.system(size: 12 * model.fontScale).monospacedDigit())
                            .foregroundStyle(.white.opacity(usage.overBudget ? 1 : 0.85))
                    }
                    ProgressView(value: usage.monthCostCents, total: max(1, usage.monthBudgetCents))
                        .tint(.white)
                    Text(usage.overBudget
                         ? "本月额度已用完，下月自动恢复；不使用 AI 的功能不受影响"
                         : "额度为会员月费的 50%（文字 + 语音大模型合计），下月初重置")
                        .font(.system(size: 11 * model.fontScale))
                        .foregroundStyle(.white.opacity(usage.overBudget ? 1 : 0.7))
                }
            }
        }
        .padding(16)
        .background(RTTheme.brandGradient, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: RTTheme.accent.opacity(0.25), radius: 12, y: 6)
    }

    // MARK: 上传录音入口

    private var uploadEntry: some View {
        Button {
            showingUpload = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.plus")
                    .font(.title3)
                    .foregroundStyle(auth.user?.effectiveTier == "premium" ? RTTheme.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("上传录音生成场景")
                        .font(.system(size: 15 * model.fontScale, weight: .semibold))
                        .foregroundStyle(RTTheme.textPrimary)
                    Text(auth.user?.effectiveTier == "premium"
                         ? "本地文件或蓝牙录音笔 · 最长 6 小时 / 300MB"
                         : "高级会员专属功能，升级后可用")
                        .font(.system(size: 12 * model.fontScale))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if auth.user?.effectiveTier == "premium" {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(16)
            .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RTTheme.hairline))
        }
        .buttonStyle(.plain)
        .disabled(auth.user?.effectiveTier != "premium")
    }

    // MARK: 账单

    private var ledger: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("账单")
                    .font(.system(size: 17 * model.fontScale, weight: .semibold))
                Spacer()
                Button {
                    Task { await model.loadBillingAccount() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
            }

            if model.billingAccount?.ledger.isEmpty != false {
                Text("暂无账单")
                    .font(.system(size: 15 * model.fontScale))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(model.billingAccount?.ledger ?? []) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.system(size: 15 * model.fontScale))
                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 11 * model.fontScale))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text((item.amountCents >= 0 ? "+" : "") + money(item.amountCents))
                            .font(.system(size: 15 * model.fontScale, weight: .medium).monospacedDigit())
                            .foregroundStyle(item.amountCents >= 0 ? .green : RTTheme.textPrimary)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .padding(16)
        .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(RTTheme.hairline))
    }

    private func money(_ cents: Int) -> String {
        "¥" + String(format: "%.2f", Double(cents) / 100)
    }
}

// MARK: - 录音上传（本地文件 / 蓝牙录音笔）

struct UploadRecordingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @StateObject private var recorder = RecorderBLEManager()
    @State private var showingFilePicker = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("从手机选择音频文件", systemImage: "folder")
                    }
                    .disabled(model.isUploadingAudio)

                    Button {
                        recorder.startScan()
                    } label: {
                        Label(bleButtonTitle, systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(model.isUploadingAudio)
                } header: {
                    Text("选择录音来源")
                } footer: {
                    Text("支持 mp3 / wav / m4a，最长 6 小时、最大 300MB。上传后服务器自动转写、过滤无效内容并生成英语练习场景，完成后自动删除音频文件。")
                }

                if recorder.files.isEmpty == false {
                    Section("录音笔中的文件") {
                        ForEach(recorder.files) { file in
                            Button {
                                recorder.download(file: file)
                            } label: {
                                HStack {
                                    Image(systemName: "waveform")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name).font(.system(size: 15 * model.fontScale))
                                        Text(String(format: "%.1f MB", Double(file.sizeBytes) / 1024 / 1024))
                                            .font(.system(size: 11 * model.fontScale))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "icloud.and.arrow.up")
                                        .font(.caption)
                                        .foregroundStyle(RTTheme.accent)
                                }
                            }
                        }
                    }
                }

                if case .downloading(let name, let progress) = recorder.phase {
                    Section("正在从录音笔读取") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(name).font(.system(size: 12 * model.fontScale))
                            ProgressView(value: progress)
                        }
                    }
                }

                if model.isUploadingAudio {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在上传并转写…")
                                .font(.system(size: 15 * model.fontScale))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if model.audioJobs.isEmpty == false {
                    Section("处理记录") {
                        ForEach(model.audioJobs) { job in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.filename).font(.system(size: 15 * model.fontScale)).lineLimit(1)
                                    Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 11 * model.fontScale))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(job.statusText)
                                    .font(.system(size: 12 * model.fontScale, weight: .semibold))
                                    .foregroundStyle(jobColor(job.status))
                            }
                        }
                    }
                }
            }
            .navigationTitle("上传录音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        recorder.disconnect()
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.mp3, .wav, .mpeg4Audio, .audio],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        await model.uploadRecording(fileURL: url)
                    }
                }
            }
            .task {
                await model.loadAudioJobs()
                recorder.onFileDownloaded = { url in
                    Task { await model.uploadRecording(fileURL: url) }
                }
            }
        }
    }

    private var bleButtonTitle: String {
        switch recorder.phase {
        case .scanning: return "正在搜索录音笔…"
        case .connecting: return "正在连接 \(recorder.deviceName ?? "录音笔")…"
        case .ready, .listing: return "已连接 \(recorder.deviceName ?? "录音笔")"
        case .downloading: return "正在读取录音…"
        case .failed(let reason): return "连接失败：\(reason)"
        case .idle: return "连接蓝牙录音笔"
        }
    }

    private func jobColor(_ status: String) -> Color {
        switch status {
        case "completed": return .green
        case "failed": return .red
        default: return .orange
        }
    }
}
