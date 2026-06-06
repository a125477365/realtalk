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
        }
    }
}
