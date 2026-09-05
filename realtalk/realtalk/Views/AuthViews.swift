import SwiftUI

/// 登录 / 注册页：默认走「邮箱 + 验证码注册 / 邮箱 + 密码登录」。
/// 微信一键登录作为次级入口保留在底部（未配置 SDK 时后端会自动走开发模式）。
struct LoginView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var model: AppModel

    @State private var isRegisterMode = false

    var body: some View {
        ZStack {
            DreamyBackdrop()

            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 30)

                    VStack(spacing: 12) {
                        VoicePulseGlyph(isActive: true, tint: .white)
                            .frame(width: 74, height: 74)

                        Text("RealTalk")
                            .font(.system(size: 40, weight: .bold))
                            .foregroundStyle(.white)

                        Text("用真实生活，进入英语环境")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.86))
                    }

                    if isRegisterMode {
                        RegisterForm()
                    } else {
                        LoginForm()

                        // 忘记密码：通过唯一邮箱链接到网页端完成修改
                        ForgotPasswordLink()
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isRegisterMode.toggle() }
                        auth.statusMessage = ""
                    } label: {
                        Text(isRegisterMode ? "已有账号？直接登录" : "没有账号？邮箱注册")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.9))
                    }

                    StatusBanner(text: auth.statusMessage)

                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

// MARK: - 登录表单（邮箱 + 密码）

private struct LoginForm: View {
    @EnvironmentObject private var auth: AuthStore

    @State private var email = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        email.contains("@") && password.count >= 6 && !auth.isBusy
    }

    var body: some View {
        VStack(spacing: 14) {
            TextField("QQ 邮箱", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focus, equals: .email)
                .authFieldStyle()

            SecureField("密码", text: $password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .authFieldStyle()

            Button {
                focus = nil
                Task { await auth.login(email: email.trimmingCharacters(in: .whitespaces), password: password) }
            } label: {
                Text(auth.isBusy ? "登录中…" : "登录")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(canSubmit ? Color(red: 0.30, green: 0.42, blue: 0.96) : .white.opacity(0.25),
                                in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
        }
    }
}

// MARK: - 忘记密码（邮件链接复位）

private struct ForgotPasswordLink: View {
    @EnvironmentObject private var auth: AuthStore
    @State private var showSheet = false
    @State private var resetEmail = ""
    @State private var sending = false
    @State private var tip = ""

    var body: some View {
        Button("忘记密码？") { showSheet = true }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.top, 2)
            .sheet(isPresented: $showSheet) {
                NavigationStack {
                    Form {
                        Section {
                            TextField("注册时使用的邮箱", text: $resetEmail)
                                .keyboardType(.emailAddress)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        } footer: {
                            Text("我们会把改密链接发到你的邮箱，点击后按提示完成重置。")
                        }
                        if tip.isEmpty == false {
                            Section { Text(tip).foregroundStyle(.secondary) }
                        }
                    }
                    .navigationTitle("重置密码")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("取消") { showSheet = false } }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(sending ? "发送中…" : "发送重置邮件") {
                                sending = true
                                Task {
                                    await auth.sendPasswordReset(email: resetEmail.trimmingCharacters(in: .whitespaces))
                                    tip = auth.statusMessage
                                    sending = false
                                }
                            }
                            .disabled(!resetEmail.contains("@") || sending)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
    }
}

// MARK: - 注册表单（邮箱 + 验证码 + 密码）

private struct RegisterForm: View {
    @EnvironmentObject private var auth: AuthStore

    @State private var email = ""
    @State private var code = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var countdown = 0
    @State private var sending = false
    @FocusState private var focus: Field?

    private enum Field { case email, code, password, confirm }

    private var emailValid: Bool { email.contains("@") && email.contains(".") }
    private var canSendCode: Bool { emailValid && countdown == 0 && !sending && !auth.isBusy }
    private var canSubmit: Bool {
        emailValid && code.count >= 4 && password.count >= 6 && password == confirm && !auth.isBusy
    }

    var body: some View {
        VStack(spacing: 14) {
            TextField("QQ 邮箱", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focus, equals: .email)
                .authFieldStyle()

            HStack(spacing: 10) {
                TextField("验证码", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focus, equals: .code)
                    .authFieldStyle()

                Button {
                    sendCode()
                } label: {
                    Text(sendButtonTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 52)
                        .background(canSendCode ? .white.opacity(0.22) : .white.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(!canSendCode)
            }

            SecureField("设置密码（至少 6 位）", text: $password)
                .textContentType(.newPassword)
                .focused($focus, equals: .password)
                .authFieldStyle()

            SecureField("确认密码", text: $confirm)
                .textContentType(.newPassword)
                .focused($focus, equals: .confirm)
                .authFieldStyle()

            if !confirm.isEmpty && password != confirm {
                Text("两次输入的密码不一致")
                    .font(.footnote)
                    .foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                focus = nil
                Task {
                    await auth.register(
                        email: email.trimmingCharacters(in: .whitespaces),
                        password: password,
                        code: code.trimmingCharacters(in: .whitespaces)
                    )
                }
            } label: {
                Text(auth.isBusy ? "注册中…" : "注册并登录")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(canSubmit ? Color(red: 0.30, green: 0.42, blue: 0.96) : .white.opacity(0.25),
                                in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)

            Text("验证码会发到你的邮箱，10 分钟内有效")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var sendButtonTitle: String {
        if sending { return "发送中…" }
        if countdown > 0 { return "\(countdown)s 后重发" }
        return "获取验证码"
    }

    private func sendCode() {
        focus = nil
        sending = true
        Task {
            let devCode = await auth.sendEmailCode(email: email.trimmingCharacters(in: .whitespaces))
            sending = false
            // 开发模式下后端直接回传验证码：自动填上，省得翻信
            if let devCode, !devCode.isEmpty { code = devCode }
            guard auth.statusMessage.contains("已发送") else { return }
            countdown = 60
            while countdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                countdown -= 1
            }
        }
    }
}

// MARK: - 共享样式

private extension View {
    /// 登录页统一的输入框样式（白色半透明，适配 DreamyBackdrop 深底）。
    func authFieldStyle() -> some View {
        self
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.25)))
    }
}

/// 兼容旧调用点：注册页。
struct RegisterView: View {
    var prefilledEmail: String = ""

    var body: some View {
        LoginView()
    }
}
