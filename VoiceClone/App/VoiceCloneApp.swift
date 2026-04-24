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
    @StateObject private var downloadManager = ModelDownloadManager()

    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environment(\.container, container)
                .environmentObject(downloadManager)
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        .commands {
            SidebarCommands()
            TextEditingCommands()
        }
        #endif
    }
}
