//
//  ModelDownloadView.swift
//  PolyJuiceVoice
//
//  First-launch setup gate. We don't pick a model for the user — they open
//  the Model Manager, browse the family × capability × precision matrix,
//  and pick what fits their hardware and use case.
//

import SwiftUI

struct ModelDownloadView: View {

    @EnvironmentObject private var downloadManager: ModelDownloadManager
    @EnvironmentObject private var selectionStore: ModelSelectionStore

    @State private var showingManager = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "waveform.circle")
                .font(.system(size: 72))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("PolyJuiceVoice")
                    .font(.largeTitle.bold())
                Text("Take on any voice — on-device")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Text("First, grab a model")
                        .font(.headline)
                    Text("PolyJuiceVoice runs entirely on this device. Pick a Qwen3-TTS variant — once any model lands you'll be in the app. Each tab will prompt you to grab whatever else it needs.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                    Text("On-device · Stored locally · No audio leaves your Mac")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)

                Button("Choose a Model") {
                    showingManager = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if !downloadManager.snapshotStates.isEmpty {
                downloadingFooter
            }

            Spacer()
        }
        .padding(40)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 460)
        #endif
        .sheet(isPresented: $showingManager) {
            ModelManagerView()
                .environmentObject(downloadManager)
                .environmentObject(selectionStore)
        }
    }

    /// Shows aggregate progress when a download is in flight from the gate
    /// (so the user gets feedback without keeping the manager sheet open).
    @ViewBuilder
    private var downloadingFooter: some View {
        let downloading = downloadManager.snapshotStates.filter { $0.value.isDownloading }
        if !downloading.isEmpty {
            VStack(spacing: 6) {
                ForEach(Array(downloading.keys), id: \.id) { snapshot in
                    if case .downloading(let progress, let file, _, let eta) = downloadManager.snapshotStates[snapshot] {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(snapshot.displayName)
                                    .font(.caption.monospacedDigit())
                                Spacer()
                                Text("\(Int(progress * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: progress)
                            Text(URL(fileURLWithPath: file).lastPathComponent + (eta.map { " · \(formatETA($0)) left" } ?? ""))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: 460)
                    }
                }
            }
        }
    }

    private func formatETA(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let secs = total % 60
        if minutes < 60 { return "\(minutes)m \(secs)s" }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(mins)m"
    }
}

#Preview {
    ModelDownloadView()
        .environmentObject(ModelDownloadManager())
        .environmentObject(ModelSelectionStore())
}
