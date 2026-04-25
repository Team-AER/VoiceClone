//
//  ModelManagerView.swift
//  VoiceClone
//
//  Per-snapshot download / delete UI for the optional model variants
//  (Base, VoiceDesign). Reachable from each feature tab when its required
//  snapshot is missing, and from Settings → Model Storage.
//

import SwiftUI

struct ModelManagerView: View {

    @EnvironmentObject private var downloadManager: ModelDownloadManager
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, the sheet opens scrolled/highlighting this snapshot —
    /// e.g. tapping "Download model" on the Clone tab opens with Base focused.
    var highlight: ModelSnapshot?

    @State private var snapshotPendingDelete: ModelSnapshot?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ModelSnapshot.allCases) { snapshot in
                        SnapshotRow(
                            snapshot: snapshot,
                            state: downloadManager.snapshotStates[snapshot] ?? .absent,
                            diskUsage: downloadManager.snapshotDiskUsage[snapshot] ?? 0,
                            isHighlighted: snapshot == highlight,
                            download: { downloadManager.startDownload(of: snapshot) },
                            delete: { snapshotPendingDelete = snapshot }
                        )
                    }
                } header: {
                    Text("Available models")
                } footer: {
                    Text("Models are downloaded from Hugging Face and stored on this device. Voice cloning needs the Base model; designing voices needs Voice Design.")
                        .foregroundStyle(.secondary)
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #else
            .listStyle(.insetGrouped)
            #endif
            .scrollContentBackground(.hidden)
            .navigationTitle("Models")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { downloadManager.rescan() }
            .alert("Delete \(snapshotPendingDelete?.displayName ?? "model")?",
                   isPresented: deleteAlertBinding,
                   presenting: snapshotPendingDelete) { snapshot in
                Button("Delete", role: .destructive) {
                    downloadManager.delete(snapshot)
                    snapshotPendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    snapshotPendingDelete = nil
                }
            } message: { snapshot in
                Text("This frees \(DiskSpace.format(downloadManager.snapshotDiskUsage[snapshot] ?? 0)) on this device. You can re-download anytime.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 460)
        #endif
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { snapshotPendingDelete != nil },
            set: { if !$0 { snapshotPendingDelete = nil } }
        )
    }
}

private struct SnapshotRow: View {

    let snapshot: ModelSnapshot
    let state: SnapshotInstallState
    let diskUsage: Int64
    let isHighlighted: Bool
    let download: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            HStack(spacing: 10) {
                Label(metaSizeText, systemImage: "internaldrive")
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

            if case .downloading(let progress, let file, let bps, let eta) = state {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                    HStack {
                        Text("\(Int(progress * 100))% — \(URL(fileURLWithPath: file).lastPathComponent)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(throughputAndEta(bps: bps, eta: eta))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if case .failed(let message) = state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, isHighlighted ? 12 : 0)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.tint.opacity(0.12))
            }
        }
    }

    private var metaSizeText: String {
        if state.isInstalled, diskUsage > 0 {
            return DiskSpace.format(diskUsage)
        }
        return DiskSpace.format(snapshot.approxBytes)
    }

    private func throughputAndEta(bps: Double, eta: Double?) -> String {
        let bpsStr = bps > 0 ? "\(DiskSpace.format(Int64(bps)))/s" : "starting…"
        guard let eta else { return bpsStr }
        return "\(bpsStr) • \(formatETA(eta)) left"
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

    @ViewBuilder
    private var statusBadge: some View {
        switch state {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
                .labelStyle(.titleAndIcon)
        case .downloading:
            Label("Downloading", systemImage: "arrow.down.circle")
                .foregroundStyle(.tint)
                .font(.caption)
                .labelStyle(.titleAndIcon)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .labelStyle(.titleAndIcon)
        case .checking, .absent:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .absent:
            Button("Download", systemImage: "arrow.down.circle", action: download)
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .labelStyle(.titleOnly)
        case .failed:
            Button("Retry", systemImage: "arrow.clockwise", action: download)
                .buttonStyle(.glass)
                .controlSize(.small)
                .labelStyle(.titleOnly)
        case .downloading:
            Button("Downloading…") {}
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(true)
        case .installed:
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                .buttonStyle(.glass)
                .controlSize(.small)
                .labelStyle(.titleOnly)
                .disabled(snapshot.isRequired)
                .help(snapshot.isRequired ? "The required model can't be deleted while the app is in use." : "Remove this model and free disk space.")
        case .checking:
            ProgressView().controlSize(.small)
        }
    }
}

#Preview {
    ModelManagerView(highlight: .base)
        .environmentObject(ModelDownloadManager())
}
