import SwiftUI
import UniformTypeIdentifiers

struct AccountView: View {
    var body: some View {
        AccountPanelView()
    }
}

/// 账户面板：会员状态 / 用量 / 会员升级 / 高级功能 / 客服工单 / 账单 / 设置入口
struct AccountPanelView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingSettings = false
    @State private var showingUpload = false
    @State private var showingMembership = false
    @State private var membershipPremiumOnly = false
    @State private var showingTickets = false

    private var isPremium: Bool { auth.user?.effectiveTier == "premium" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    memberCard
                    upgradeEntry
                    premiumFeatures
                    supportEntry
                    ledger
                    accountInfoCard
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
            .sheet(isPresented: $showingMembership) { MembershipView(premiumOnly: membershipPremiumOnly) }
            .sheet(isPresented: $showingTickets) { SupportTicketsView() }
            .task {
                await model.loadBillingAccount()
                if model.planCatalog.isEmpty { await model.loadPlanCatalog() }
            }
        }
    }

    // MARK: 会员卡（不显示余额，用量以百分比展示）

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
                        Text(auth.user?.tierName ?? "非会员")
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
            }

            if let usage = model.billingAccount?.usage {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(usage.isMember ? "本月额度用量" : "今日免费用量")
                            .font(.system(size: 12 * model.fontScale))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Text("\(usage.usagePercentInt)%")
                            .font(.system(size: 12 * model.fontScale).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    ProgressView(value: min(1, usage.usagePercent / 100))
                        .tint(.white)
                    if usage.overBudget {
                        Text(usage.isMember ? "本月额度已用完，下月自动恢复" : "今日免费额度已用完，升级会员解锁更多用量")
                            .font(.system(size: 11 * model.fontScale))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .padding(16)
        .background(RTTheme.brandGradient, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: RTTheme.accent.opacity(0.25), radius: 12, y: 6)
    }

    // MARK: 升级 / 会员入口

    private var upgradeEntry: some View {
        Button {
            membershipPremiumOnly = false
            showingMembership = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "crown.fill").font(.title3).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isPremium ? "续费高级会员" : (auth.user?.effectiveTier == "basic" ? "续费 / 升级会员" : "升级会员"))
                        .font(.system(size: 15 * model.fontScale, weight: .semibold))
                        .foregroundStyle(RTTheme.textPrimary)
                    Text(isPremium ? "延长高级会员有效期" : "解锁更多每日用量与高级功能")
                        .font(.system(size: 12 * model.fontScale))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RTTheme.hairline))
        }
        .buttonStyle(.plain)
    }

    // MARK: 高级会员专属功能（上传录音 + 实时语音对话，放在一起）

    private var premiumFeatures: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("高级会员专属")
                .font(.system(size: 12 * model.fontScale, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                premiumRow(
                    icon: "waveform.badge.plus",
                    title: "上传已有语音文件生成场景",
                    subtitle: isPremium ? "支持 mp3 / wav / m4a · 最长 6 小时" : "高级会员专属，升级后可用",
                    action: { if isPremium { showingUpload = true } else { membershipPremiumOnly = true; showingMembership = true } }
                )
                Divider().padding(.leading, 44)
                premiumRow(
                    icon: "mic.circle.fill",
                    title: "沉浸式直连模型对话练习",
                    subtitle: isPremium ? "在「设置」开启后，沉浸式对话直接与语音大模型对话" : "高级会员专属，升级后可用",
                    action: { if isPremium { showingSettings = true } else { membershipPremiumOnly = true; showingMembership = true } }
                )
            }
            .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RTTheme.hairline))
        }
    }

    private func premiumRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isPremium ? RTTheme.accent : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15 * model.fontScale, weight: .semibold))
                        .foregroundStyle(RTTheme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12 * model.fontScale))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isPremium ? "chevron.right" : "lock.fill")
                    .font(.caption)
                    .foregroundStyle(isPremium ? Color.secondary : Color.orange)
            }
            .padding(16)
        }
        .buttonStyle(.plain)
    }

    // MARK: 账号（从设置移到这里）

    private var accountInfoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            infoRow("登录方式", auth.user?.displayName ?? "微信用户")
            Divider()
            Button(role: .destructive) {
                auth.logout()
                dismiss()
            } label: {
                Text("退出登录").font(.system(size: 15 * model.fontScale))
            }
        }
        .padding(16)
        .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(RTTheme.hairline))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 15 * model.fontScale)).foregroundStyle(RTTheme.textPrimary)
            Spacer()
            Text(value).font(.system(size: 14 * model.fontScale)).foregroundStyle(.secondary)
        }
    }

    // MARK: 客服工单入口

    private var supportEntry: some View {
        Button {
            showingTickets = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.title3).foregroundStyle(RTTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("客服工单")
                        .font(.system(size: 15 * model.fontScale, weight: .semibold))
                        .foregroundStyle(RTTheme.textPrimary)
                    Text("反馈问题、申请退款等")
                        .font(.system(size: 12 * model.fontScale))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(RTTheme.hairline))
        }
        .buttonStyle(.plain)
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

private func acctMoney(_ cents: Int) -> String { "¥" + String(format: "%.2f", Double(cents) / 100) }

// MARK: - 会员（先选套餐，再出微信/支付宝付款方式）

struct MembershipView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPlan: PlanItem?
    let premiumOnly: Bool

    init(premiumOnly: Bool = false) {
        self.premiumOnly = premiumOnly
    }

    private var displayPlans: [PlanItem] {
        premiumOnly ? model.availablePlans.filter { $0.tier == "premium" } : model.availablePlans
    }

    var body: some View {
        NavigationStack {
            List {
                Section(sectionTitle) {
                    ForEach(displayPlans) { plan in
                        Button { selectedPlan = plan } label: { planRow(plan) }
                            .buttonStyle(.plain)
                    }
                }
                if let order = model.rechargeOrder {
                    Section("待支付") {
                        Text(order.message)
                        if let acc = order.receiverAccount, acc.isEmpty == false {
                            LabeledContent("收款账号", value: acc)
                        }
                        LabeledContent("订单号", value: order.orderId)
                        Button("我已完成支付") { Task { await model.confirmRecharge() } }
                    }
                }
            }
            .navigationTitle("会员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .sheet(item: $selectedPlan) { plan in PaymentMethodSheet(plan: plan) }
            .task { if model.planCatalog.isEmpty { await model.loadPlanCatalog() } }
        }
    }

    private var sectionTitle: String {
        if premiumOnly { return "升级高级会员" }
        switch auth.user?.effectiveTier {
        case "premium": return "续费高级会员"
        case "basic": return "续费基础 / 升级高级"
        default: return "选择会员套餐"
        }
    }

    private func actionLabel(_ plan: PlanItem) -> String {
        let tier = auth.user?.effectiveTier ?? "free"
        if plan.tier == tier { return "续费" }
        if plan.tier == "premium" && tier == "basic" { return "升级" }
        return "开通"
    }

    private func planRow(_ plan: PlanItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(plan.title).font(.system(size: 16 * model.fontScale, weight: .semibold))
                        .foregroundStyle(RTTheme.textPrimary)
                    Text(actionLabel(plan))
                        .font(.system(size: 10 * model.fontScale, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((plan.tier == "premium" ? Color.orange : RTTheme.accent).opacity(0.15), in: Capsule())
                        .foregroundStyle(plan.tier == "premium" ? .orange : RTTheme.accent)
                }
                Text(plan.months > 1 ? "每月 \(acctMoney(plan.perMonthCents))" : "按月")
                    .font(.system(size: 12 * model.fontScale)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(acctMoney(plan.priceCents))
                .font(.system(size: 16 * model.fontScale, weight: .semibold).monospacedDigit())
                .foregroundStyle(RTTheme.textPrimary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct PaymentMethodSheet: View {
    let plan: PlanItem
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var method = "wechat"

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.title).font(.system(size: 20 * model.fontScale, weight: .bold))
                    Text(acctMoney(plan.priceCents) + (plan.months > 1 ? " · 每月 \(acctMoney(plan.perMonthCents))" : ""))
                        .font(.system(size: 14 * model.fontScale)).foregroundStyle(.secondary)
                }

                Text("选择付款方式").font(.system(size: 13 * model.fontScale)).foregroundStyle(.secondary)
                BrandSegmentedPicker(
                    selection: $method,
                    options: [("wechat", "微信支付"), ("alipay", "支付宝")],
                    fontScale: model.fontScale
                )

                Button {
                    Task {
                        await model.subscribe(planId: plan.id, method: method)
                        dismiss()
                    }
                } label: {
                    Text("确认开通 \(acctMoney(plan.priceCents))")
                        .font(.system(size: 16 * model.fontScale, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(RTTheme.brandGradient, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.isWorking)
                Spacer()
            }
            .padding(20)
            .navigationTitle("确认开通")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("取消") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 客服工单

struct SupportTicketsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var category = "feedback"
    @State private var subject = ""
    @State private var body_ = ""

    private let categories: [(String, String)] = [("feedback", "反馈"), ("refund", "退款"), ("bug", "问题"), ("other", "其他")]

    var body: some View {
        NavigationStack {
            Form {
                Section("提交工单") {
                    Picker("类型", selection: $category) {
                        ForEach(categories, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    TextField("标题", text: $subject)
                    TextEditor(text: $body_).frame(minHeight: 90)
                    Button("提交工单") {
                        Task {
                            if await model.submitSupportTicket(category: category, subject: subject, body: body_) {
                                subject = ""; body_ = ""
                            }
                        }
                    }
                    .disabled(subject.trimmingCharacters(in: .whitespaces).isEmpty || body_.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if model.myTickets.isEmpty == false {
                    Section("我的工单") {
                        ForEach(model.myTickets) { ticket in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(ticket.subject).font(.system(size: 15 * model.fontScale, weight: .semibold))
                                    Spacer()
                                    Text(ticket.statusText)
                                        .font(.system(size: 11 * model.fontScale, weight: .semibold))
                                        .foregroundStyle(ticket.status == "resolved" ? .green : .orange)
                                }
                                Text(ticket.body).font(.system(size: 13 * model.fontScale)).foregroundStyle(.secondary)
                                if let reply = ticket.adminReply, reply.isEmpty == false {
                                    Text("客服回复：\(reply)")
                                        .font(.system(size: 13 * model.fontScale))
                                        .foregroundStyle(RTTheme.accent)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .navigationTitle("客服工单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .task { await model.loadMyTickets() }
        }
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
            .navigationTitle("上传语音文件")
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
