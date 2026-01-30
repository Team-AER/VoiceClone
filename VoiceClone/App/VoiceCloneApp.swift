//
//  VoiceCloneApp.swift
//  VoiceClone
//
//  Created by Prakhar Shukla on 28-01-2026.
//

import SwiftUI

@main
struct VoiceCloneApp: App {

    @StateObject private var container = DIContainer()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(container)
                .environment(\.container, container)
        }
    }
}
