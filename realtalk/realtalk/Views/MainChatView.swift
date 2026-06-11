import SwiftUI

struct MainChatView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var speech: SpeechCaptureManager
    @EnvironmentObject private var practiceSpeech: SpeechPracticeManager
    @EnvironmentObject private var voice: VoicePromptPlayer

    @State private var draft = ""
    @State private var showingAccount = false
    @State private var roleDialogScenario: ScenarioSummary?

    var body: some View {
        NavigationStack {
            ZStack {
                DreamyBackdrop()

                VStack(spacing: 0) {
                    topBar
                    if model.todayScenarios.isEmpty == false {
                        scenarioStrip
                    }
                    messages
                    composer
                }
            }
            .sheet(isPresented: $showingAccount) {
                AccountPanelView()
                    .presentationDetents([.medium, .large])
            }
            .confirmationDialog(
                roleDialogScenario.map { "练习「\($0.title)」，你想扮演谁？" } ?? "选择角色",
                isPresented: Binding(
                    get: { roleDialogScenario != nil },
                    set: { if $0 == false { roleDialogScenario = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let summary = roleDialogScenario {
                    ForEach(summary.roles.filter(\.isUserCandidate)) { role in
                        Button("\(role.name)（\(role.description)）") {
                            roleDialogScenario = nil
                            Task { await model.startScenarioPractice(summary, roleId: role.id) }
                        }
                    }
                    Button("取消", role: .cancel) { roleDialogScenario = nil }
                }
            }
        }
    }

    /// 今日真实对话场景：默认展示当天最新生成的场景列表，点卡片选角色直接开练
    private var scenarioStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("今日场景")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Button {
                    Task { await model.loadTodayScenarios() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .disabled(model.isLoadingScenarios)
            }
            .padding(.horizontal, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.todayScenarios) { summary in
                        Button {
                            roleDialogScenario = summary
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(summary.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(summary.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                HStack(spacing: 6) {
                                    Label("\(summary.lineCount) 句", systemImage: "text.bubble")
                                    Label(summary.createdAt.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .frame(width: 210, alignment: .leading)
                            .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
            }
        }
        .padding(.vertical, 8)
        .background(.black.opacity(0.06))
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                showingAccount = true
            } label: {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.82))
                    Text((auth.user?.displayName ?? "微信").prefix(1))
                        .font(.headline)
                        .foregroundStyle(.blue)
                }
                .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("RealTalk")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
            }

            Spacer()

            Button {
                Task {
                    if speech.isRecording {
                        await model.sendMainChatMessage("停止录音")
                    } else {
                        await model.sendMainChatMessage("开始录音")
                    }
                }
            } label: {
                Image(systemName: speech.isRecording ? "stop.circle.fill" : "waveform.circle")
                    .font(.title2)
                    .foregroundStyle(speech.isRecording ? .red : .white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black.opacity(0.10))
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.chatMessages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .background(.white.opacity(0.90))
            .onChange(of: model.chatMessages.count) { _, _ in
                if let last = model.chatMessages.last {
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if practiceSpeech.partialText.isEmpty == false {
                Text(practiceSpeech.partialText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }

            HStack(spacing: 10) {
                TextField("向 RealTalk 说出你的目标", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

                Button {
                    Task { await sendDraft() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)

                Button {
                    Task { await model.toggleVoiceConversation() }
                } label: {
                    VoicePulseGlyph(
                        isActive: model.isVoiceConversationActive || practiceSpeech.isListening || speech.isRecording || voice.isSpeaking,
                        tint: model.isVoiceConversationActive ? .orange : .blue
                    )
                    .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .disabled(model.roleplay == nil || model.isWorking)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .padding(.top, 10)
        .background(.white.opacity(0.92))
    }

    private var statusText: String {
        if voice.isSpeaking {
            return "AI 正在说话"
        }
        if practiceSpeech.isListening {
            return "正在听你说英语"
        }
        if speech.isRecording {
            return "正在采集真实对话"
        }
        return "用真实生活练英语"
    }

    private func sendDraft() async {
        let text = draft
        draft = ""
        await model.sendMainChatMessage(text)
    }
}

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.sender == .user {
                Spacer(minLength: 46)
            }

            Text(message.text)
                .font(.body)
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(background, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 310, alignment: alignment)

            if message.sender != .user {
                Spacer(minLength: 46)
            }
        }
        .frame(maxWidth: .infinity, alignment: rowAlignment)
    }

    private var background: Color {
        switch message.sender {
        case .user:
            return .blue
        case .assistant:
            return Color(.secondarySystemGroupedBackground)
        case .system:
            return Color(.systemYellow).opacity(0.22)
        }
    }

    private var foreground: Color {
        message.sender == .user ? .white : .primary
    }

    private var rowAlignment: Alignment {
        message.sender == .user ? .trailing : .leading
    }

    private var alignment: Alignment {
        message.sender == .user ? .trailing : .leading
    }
}

struct AccountPanelView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    @State private var amountCents = 3000
    @State private var method = "wechat"
    @State private var showingSettings = false

    private let amounts = [1000, 3000, 6800, 12800]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    profile
                    recharge
                    ledger
                    StatusBanner(text: model.statusMessage)
                }
                .padding(18)
            }
            .navigationTitle("账户")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .task {
                await model.loadBillingAccount()
            }
        }
    }

    private var profile: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.14))
                Text((auth.user?.displayName ?? auth.user?.loginIdentifier ?? "R").prefix(1).uppercased())
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(auth.user?.displayName ?? "微信用户")
                    .font(.headline)
                    .lineLimit(1)
                Text("微信授权已登录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("余额 \(money(auth.user?.balanceCents ?? 0))")
                    .font(.title3.weight(.semibold))
            }
            Spacer()
            Button {
                auth.logout()
                dismiss()
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var recharge: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("充值")
                .font(.headline)

            Picker("支付方式", selection: $method) {
                Text("微信").tag("wechat")
                Text("支付宝").tag("alipay")
            }
            .pickerStyle(.segmented)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(amounts, id: \.self) { amount in
                    Button {
                        amountCents = amount
                    } label: {
                        Text(money(amount))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(amount == amountCents ? .blue : .gray)
                }
            }

            Button {
                Task { await model.createRecharge(amountCents: amountCents, method: method) }
            } label: {
                Label("生成付款单", systemImage: "creditcard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if let order = model.rechargeOrder {
                VStack(alignment: .leading, spacing: 8) {
                    Text(order.message)
                        .font(.subheadline)
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
                        Text("我已付款")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var ledger: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("账单")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await model.loadBillingAccount() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }

            if model.billingAccount?.ledger.isEmpty != false {
                Text("暂无账单")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(model.billingAccount?.ledger ?? []) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(money(item.amountCents))
                            .font(.subheadline.monospacedDigit())
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(16)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func money(_ cents: Int) -> String {
        "¥" + String(format: "%.2f", Double(cents) / 100)
    }
}
