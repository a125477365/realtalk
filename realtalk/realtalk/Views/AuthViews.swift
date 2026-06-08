import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var auth: AuthStore

    var body: some View {
        ZStack {
            DreamyBackdrop()

            VStack(spacing: 30) {
                Spacer()

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

                Button {
                    Task { await auth.loginWithWeChat() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "message.fill")
                        Text(auth.isBusy ? "正在授权" : "微信快速登录")
                            .fontWeight(.semibold)
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(red: 0.05, green: 0.68, blue: 0.30), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(auth.isBusy)
                .padding(.horizontal, 34)

                StatusBanner(text: auth.statusMessage)
                    .padding(.horizontal, 34)

                Spacer()
            }
        }
    }
}

struct RegisterView: View {
    var prefilledEmail: String = ""

    var body: some View {
        LoginView()
    }
}
