import SwiftUI

/// 闲鱼卡密兑换页：用户购买虚拟商品后输入 12 位数字码，立即开通会员/加余额。
struct RedeemCodeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthStore
    @EnvironmentObject var model: AppModel
    @State private var code = ""
    @State private var submitting = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 说明卡
                    VStack(alignment: .leading, spacing: 8) {
                        Label("如何获取兑换码", systemImage: "info.circle.fill")
                            .font(.system(size: 15 * model.fontScale, weight: .semibold))
                            .foregroundStyle(RTTheme.accent)
                        Text("在闲鱼搜索 RealTalk，卖家会自动发送一串 12 位数字。输入后即可兑换 token。")
                            .font(.system(size: 13 * model.fontScale))
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RTTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                    // 输入区
                    VStack(alignment: .leading, spacing: 10) {
                        Text("兑换码")
                            .font(.system(size: 15 * model.fontScale, weight: .semibold))
                        TextField("请输入12位数字", text: $code)
                            .keyboardType(.numberPad)
                            .font(.system(size: 22 * model.fontScale, weight: .semibold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .kerning(3)
                            .padding(14)
                            .background(RTTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(RTTheme.hairline))
                            .onChange(of: code) { _, newValue in
                                // 只留数字，最多 12 位
                                let filtered = String(newValue.filter { $0.isNumber }.prefix(12))
                                if filtered != newValue { code = filtered }
                            }
                        Text("码在闲鱼聊天窗口中自动发送，可直接复制粘贴")
                            .font(.system(size: 12 * model.fontScale))
                            .foregroundStyle(.secondary)
                    }

                    if let resultMessage {
                        StatusBanner(text: resultMessage)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13 * model.fontScale))
                            .foregroundStyle(.red)
                    }

                    Button {
                        submit()
                    } label: {
                        HStack {
                            if submitting { ProgressView().tint(.white) }
                            Text(submitting ? "兑换中..." : "立即兑换")
                                .font(.system(size: 16 * model.fontScale, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(code.count == 12 && !submitting ? AnyShapeStyle(RTTheme.brandGradient) : AnyShapeStyle(Color.gray.opacity(0.4)), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                    }
                    .disabled(code.count != 12 || submitting)

                    Spacer(minLength: 20)
                }
                .padding(16)
            }
            .background(RTTheme.background)
            .navigationTitle("兑换码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func submit() {
        submitting = true
        errorMessage = nil
        resultMessage = nil
        Task {
            do {
                let message = try await model.redeemCode(code)
                await MainActor.run {
                    resultMessage = message
                    code = ""
                }
            } catch let APIClientError.server(detail) {
                await MainActor.run { errorMessage = detail }
            } catch {
                await MainActor.run { errorMessage = "网络异常，请稍后再试" }
            }
            await MainActor.run { submitting = false }
        }
    }
}
