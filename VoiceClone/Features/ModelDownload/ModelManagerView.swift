//
//  ModelManagerView.swift
//  VoiceClone
//
//  Per-snapshot download UI for the optional model variants (Base, VoiceDesign).
//  Reachable from each feature tab when its required snapshot is missing.
//

import SwiftUI

struct ModelManagerView: View {

    @EnvironmentObject private var downloadManager: ModelDownloadManager
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, the sheet opens scrolled/highlighting this snapshot —
    /// e.g. tapping "Download model" on the Clone tab opens with Base focused.
    var highlight: ModelSnapshot?

    var body: some View {
        NavigationStack {
            List(ModelSnapshot.allCases) { snapshot in
                SnapshotRow(snapshot: snapshot,
                            state: downloadManager.snapshotStates[snapshot] ?? .absent,
                            isHighlighted: snapshot == highlight) {
                    downloadManager.startDownload(of: snapshot)
                }
            }
            .navigationTitle("Model Manager")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { downloadManager.rescan() }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 420)
        #endif
    }
}

private struct SnapshotRow: View {

    let snapshot: ModelSnapshot
    let state: SnapshotInstallState
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.displayName)
                        .font(.headline)
                    Text(snapshot.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                statusBadge
            }

            HStack(spacing: 8) {
                Label(humanReadableSize, systemImage: "internaldrive")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if snapshot.isRequired {
                    Label("Required", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                Spacer()
                actionButton
            }

            if case .downloading(let progress, let file) = state {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                    Text("\(Int(progress * 100))% — \(URL(fileURLWithPath: file).lastPathComponent)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if case .failed(let message) = state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .background(isHighlighted ? Color.accentColor.opacity(0.08) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var humanReadableSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: snapshot.approxBytes)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch state {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .downloading:
            Label("Downloading", systemImage: "arrow.down.circle")
                .foregroundStyle(.tint)
                .font(.caption)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .checking, .absent:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .absent, .failed:
            Button(state == .absent ? "Download" : "Retry", action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .downloading:
            Button("Downloading…") {}
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)
        case .installed:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        }
    }
}

#Preview {
    ModelManagerView(highlight: .base)
        .environmentObject(ModelDownloadManager())
}
