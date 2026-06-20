//
//  realtalkApp.swift
//  realtalk
//
//  Created by 谭坚 on 2026/6/3.
//

import SwiftUI

@main
struct realtalkApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.transcripts)
                .environmentObject(model.speech)
                .environmentObject(model.auth)
                .environmentObject(model.subscription)
                .environmentObject(model.practiceSpeech)
                .environmentObject(model.voice)
                .environmentObject(model.realtime)
                .onAppear { WeChatAuthManager.shared.registerIfNeeded() }
                .onOpenURL { url in
                    _ = WeChatAuthManager.shared.handleOpen(url: url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    _ = WeChatAuthManager.shared.handleUniversalLink(activity)
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await model.handlePendingShortcutAction() }
                }
        }
    }
}
