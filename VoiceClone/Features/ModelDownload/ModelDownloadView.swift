//
//  ModelDownloadView.swift
//  VoiceClone
//

import SwiftUI

struct ModelDownloadView: View {

    @EnvironmentObject private var downloadManager: ModelDownloadManager

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "waveform.circle")
                .font(.system(size: 72))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("VoiceClone")
                    .font(.largeTitle.bold())
                Text("AI voice synthesis, on-device")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            switch downloadManager.state {
            case .checking:
                ProgressView("Checking for models…")

            case .awaitingPermission:
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Text("On-Device AI Models Required")
                            .font(.headline)
                        Text("VoiceClone needs to download ~4 GB of AI models to synthesize speech entirely on your device. No audio data ever leaves your Mac.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield")
                        Text("4 GB · One-time download · Stored locally")
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                    Button("Download Models") {
                        downloadManager.startDownload()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

            case .downloading(let file, _, let overall):
                VStack(spacing: 12) {
                    ProgressView(value: overall)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 400)

                    Text("Downloading \(URL(fileURLWithPath: file).lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("\(Int(overall * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

            case .failed(let message):
                VStack(spacing: 16) {
                    Label("Download failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)

                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)

                    Button("Try Again") {
                        downloadManager.retry()
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .ready:
                EmptyView()
            }

            Spacer()
        }
        .padding(40)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 400)
        #endif
    }
}

#Preview {
    ModelDownloadView()
        .environmentObject(ModelDownloadManager())
}
