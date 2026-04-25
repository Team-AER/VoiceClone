//
//  RootView.swift
//  PolyJuiceVoice
//
//  Top-level routing. With *no* models installed we land on the
//  first-launch download popup (`ModelDownloadView`). The moment any
//  snapshot lands on disk the user moves into the main app — per-tab
//  `MissingCapabilityPrompt`s handle the "you still need a model for
//  this specific feature" flow from there.
//

import SwiftUI

struct RootView: View {

    @EnvironmentObject private var downloadManager: ModelDownloadManager

    var body: some View {
        if anySnapshotInstalled {
            ContentView()
        } else {
            ModelDownloadView()
        }
    }

    /// Pulled off `downloadManager.snapshotStates` so the view re-renders
    /// the moment a download completes (versus a one-shot disk probe).
    private var anySnapshotInstalled: Bool {
        downloadManager.snapshotStates.values.contains { $0.isInstalled }
    }
}
