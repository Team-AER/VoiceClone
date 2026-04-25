//
//  PolyJuiceVoiceApp.swift
//  PolyJuiceVoice
//
//  Created by Prakhar Shukla on 28-01-2026.
//

import SwiftUI

@main
struct PolyJuiceVoiceApp: App {

    @StateObject private var container = DIContainer()
    @StateObject private var downloadManager = ModelDownloadManager()
    @StateObject private var selectionStore = ModelSelectionStore()

    init() {
        // Pin the MLX default device to .gpu and set sensible Metal memory
        // limits before any DIContainer / MLXTTSService init touches MLX.
        MLXRuntime.bootstrap()
    }

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
                .environmentObject(selectionStore)
                .task {
                    // Wire the download manager to the selection store so
                    // deletions of the user's chosen variant clear the
                    // selection (re-prompting next time).
                    downloadManager.attach(selectionStore: selectionStore)
                }
        }
        #if os(macOS)
        .defaultSize(width: 980, height: 640)
        // .contentMinSize lets SwiftUI propagate the content's *minimum*
        // size to NSWindow but leaves the maximum unbounded. (.contentSize
        // also propagates the max — and our content reports `.infinity`
        // for some hierarchies, which translates into a window that
        // refuses to shrink past whatever it last opened at.)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            TextEditingCommands()
        }
        #endif
    }
}
