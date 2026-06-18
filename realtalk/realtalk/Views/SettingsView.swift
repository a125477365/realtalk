import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("对话与字幕") {
                    Toggle("显示双语字幕", isOn: $model.showDialogueContent)
                    Toggle("自动朗读 AI 台词", isOn: $model.autoSpeakAI)
                    Toggle("连续语音对话", isOn: $model.continuousVoiceMode)
                    Picker("默认指导方式", selection: $model.guidanceMode) {
                        ForEach(AppModel.GuidanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Slider(value: $model.fontScale, in: 0.85...1.35, step: 0.05) {
                        Text("字体大小")
                    } minimumValueLabel: {
                        Text("小")
                    } maximumValueLabel: {
                        Text("大")
                    }
                    Text("当前字体 \(Int(model.fontScale * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("按时间窗自动采集", isOn: $model.autoCaptureEnabled)
                    if model.autoCaptureEnabled {
                        DatePicker("开始时间", selection: $model.autoCaptureStart, displayedComponents: .hourAndMinute)
                        DatePicker("结束时间", selection: $model.autoCaptureEnd, displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("真实对话采集")
                } footer: {
                    Text("开启后，App 在前台运行时会在设定时间窗内自动采集并转写周围对话，采集期间状态栏会有明显提示。请在征得在场人员同意后使用。")
                }

                Section("账号") {
                    LabeledContent("登录方式", value: auth.user?.displayName ?? "微信用户")
                    LabeledContent("用户 ID", value: String((auth.user?.id ?? "—").prefix(8)) + "…")
                    LabeledContent("套餐", value: auth.user?.tierName ?? "免费用户")
                    NavigationLink("会员与充值") {
                        BillingSettingsView()
                    }
                    Button("退出登录", role: .destructive) {
                        auth.logout()
                        dismiss()
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: appVersion)
                    LabeledContent("服务地址", value: AppConfig.apiBaseURL.absoluteString)
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: model.autoCaptureEnabled) { _, _ in model.saveCaptureSchedule() }
            .onChange(of: model.autoCaptureStart) { _, _ in model.saveCaptureSchedule() }
            .onChange(of: model.autoCaptureEnd) { _, _ in model.saveCaptureSchedule() }
            .onChange(of: model.fontScale) { _, _ in model.savePracticePreferences() }
            .onChange(of: model.guidanceMode) { _, _ in model.savePracticePreferences() }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

private struct BillingSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var method = "wechat"

    var body: some View {
        Form {
            Section("套餐") {
                Picker("支付方式", selection: $method) {
                    Text("微信支付").tag("wechat")
                    Text("支付宝").tag("alipay")
                }
                .pickerStyle(.segmented)

                ForEach(model.planCatalog) { plan in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plan.title).font(.headline)
                                Text(plan.months > 1 ? "每月 \(settingsMoney(plan.perMonthCents)) · 共 \(settingsMoney(plan.priceCents))" : "每月 \(settingsMoney(plan.perMonthCents))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("开通") {
                                Task { await model.subscribe(planId: plan.id, method: method) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(plan.tier == "premium" ? .orange : RTTheme.accent)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let order = model.rechargeOrder {
                Section("待支付") {
                    Text(order.message)
                    if let account = order.receiverAccount, account.isEmpty == false {
                        LabeledContent("收款账号", value: account)
                    }
                    LabeledContent("订单号", value: order.orderId)
                    Button("我已完成支付") {
                        Task { await model.confirmRecharge() }
                    }
                }
            }
        }
        .navigationTitle("会员与充值")
        .task {
            if model.planCatalog.isEmpty { await model.loadPlanCatalog() }
            await model.loadBillingAccount()
        }
    }
}

private func settingsMoney(_ cents: Int) -> String {
    String(format: "¥%.2f", Double(cents) / 100)
}
