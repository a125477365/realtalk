import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.auth.isAuthenticated {
                MainChatView()
            } else {
                LoginView()
            }
        }
        .task {
            await model.bootstrap()
        }
    }
}
