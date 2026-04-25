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
        } else if !downloadManager.isInitialScanComplete {
            // Validation runs on a background task; show a thin loader until
            // it finishes so we don't briefly flash the download prompt at a
            // user who already has models on disk.
            scanningPlaceholder
        } else {
            ModelDownloadView()
        }
    }

    private var scanningPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Checking installed models…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Pulled off `downloadManager.snapshotStates` so the view re-renders
    /// the moment a download completes (versus a one-shot disk probe).
    private var anySnapshotInstalled: Bool {
        downloadManager.snapshotStates.values.contains { $0.isInstalled }
    }
}
