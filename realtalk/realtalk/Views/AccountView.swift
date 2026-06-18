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

    @State private var method = "wechat"
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
                    Circle().fill(RTTheme.accent.opacity(0.16))
                    Text((auth.user?.displayName ?? "我").prefix(1))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(RTTheme.accent)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(auth.user?.displayName ?? "微信用户")
                            .font(.headline)
                        Text(auth.user?.tierName ?? "免费用户")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                auth.user?.effectiveTier == "premium"
                                    ? Color.orange.opacity(0.18)
                                    : RTTheme.accent.opacity(0.12),
                                in: Capsule()
                            )
                            .foregroundStyle(auth.user?.effectiveTier == "premium" ? .orange : RTTheme.accent)
                    }
                    if let expires = auth.user?.planExpiresAt {
                        Text("有效期至 \(expires.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(money(auth.user?.balanceCents ?? 0))
                        .font(.title3.weight(.bold))
                    Text("余额")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let usage = model.billingAccount?.usage {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("今日 AI 用量")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(usage.todayTokens) / \(usage.dailyLimit) tokens")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(usage.overLimit ? .red : .secondary)
                    }
                    ProgressView(value: Double(usage.todayTokens), total: Double(max(1, usage.dailyLimit)))
                        .tint(usage.overLimit ? .red : RTTheme.accent)
                    if usage.overLimit {
                        Text("已达今日上限，明天自动恢复；不使用 AI 的功能不受影响")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(16)
        .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(RTTheme.hairline))
    }

    // MARK: 套餐

    private var plans: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("会员套餐")
                .font(.headline)
            Text("会员每日有 token 用量限额；高级会员可上传录音文件生成场景")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("支付方式", selection: $method) {
                Text("微信支付").tag("wechat")
                Text("支付宝").tag("alipay")
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.planCatalog) { plan in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(plan.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(plan.tier == "premium" ? .orange : RTTheme.accent)
                            Text(money(plan.perMonthCents))
                                .font(.title3.weight(.bold))
                            Text(plan.months > 1 ? "每月 · 共 \(money(plan.priceCents))" : "每月")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button {
                                Task { await model.subscribe(planId: plan.id, method: method) }
                            } label: {
                                Text("开通")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(plan.tier == "premium" ? .orange : RTTheme.accent)
                            .disabled(model.isWorking)
                        }
                        .padding(12)
                        .frame(width: 132)
                        .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(
                            plan.tier == "premium" ? Color.orange.opacity(0.4) : RTTheme.hairline
                        ))
                    }
                }
            }
        }
    }

    // MARK: 待支付订单（开通会员后出现）

    @ViewBuilder
    private var orderPanel: some View {
        if let order = model.rechargeOrder {
            VStack(alignment: .leading, spacing: 10) {
                Text("待支付")
                    .font(.headline)
                Text(order.message)
                    .font(.subheadline)
                if let url = order.qrCodeUrl, let u = URL(string: url) {
                    AsyncImage(url: u) { img in img.resizable().scaledToFit() } placeholder: { ProgressView() }
                        .frame(width: 180, height: 180)
                        .frame(maxWidth: .infinity)
                }
                Text("订单号：\(order.orderId)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let account = order.receiverAccount, account.isEmpty == false {
                    Text("收款账号：\(account)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await model.confirmRecharge() }
                } label: {
                    Text("我已完成支付")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(RTTheme.accent)
            }
            .padding(16)
            .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RTTheme.hairline))
        }
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RTTheme.textPrimary)
                    Text(auth.user?.effectiveTier == "premium"
                         ? "本地文件或蓝牙录音笔 · 最长 6 小时 / 300MB"
                         : "高级会员专属功能，升级后可用")
                        .font(.caption)
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
                    .font(.headline)
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
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(model.billingAccount?.ledger ?? []) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.subheadline)
                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text((item.amountCents >= 0 ? "+" : "") + money(item.amountCents))
                            .font(.subheadline.monospacedDigit().weight(.medium))
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
                                        Text(file.name).font(.subheadline)
                                        Text(String(format: "%.1f MB", Double(file.sizeBytes) / 1024 / 1024))
                                            .font(.caption2)
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
                            Text(name).font(.caption)
                            ProgressView(value: progress)
                        }
                    }
                }

                if model.isUploadingAudio {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在上传并转写…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if model.audioJobs.isEmpty == false {
                    Section("处理记录") {
                        ForEach(model.audioJobs) { job in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.filename).font(.subheadline).lineLimit(1)
                                    Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(job.statusText)
                                    .font(.caption.weight(.semibold))
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
