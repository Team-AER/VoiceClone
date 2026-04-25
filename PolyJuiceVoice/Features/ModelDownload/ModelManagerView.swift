//
//  ModelManagerView.swift
//  PolyJuiceVoice
//
//  Setup dialog. Tabs along the top split the
//  (family × capability × precision) matrix by *user-facing* capability —
//  Preset Voices, Voice Cloning, Voice Design. Inside each tab we render
//  one Liquid Glass card per (family, snapshotCapability) pair, with a
//  precision pill row inside.
//
//  Why grouped by (family, snapshotCapability) and not just by family:
//  the `customVoice` tab accepts both Base and CustomVoice snapshots
//  (Base also covers preset voices). Lumping them under "0.6B" gave us
//  duplicate precision pills and a confusing UX. One card per snapshot
//  family + capability keeps the IDs unique and makes the trade-off
//  explicit ("Base also covers cloning" vs "CustomVoice is preset-only").
//
//  Performance notes:
//   • `VariantCard` takes plain values (not the ObservableObject stores),
//     conforms to Equatable, so SwiftUI's prop-diff can skip cards whose
//     slice of the matrix didn't move when `snapshotStates` ticks during
//     a download.
//   • `ModelDownloadManager.publishProgress` throttles emits to ~7Hz —
//     URLSession's `didWriteData` fires far more often than that.
//   • Pills don't carry their own `.glassEffect`. The card is glass; the
//     pills sit on top with a cheap material capsule. Per-pill glass at
//     ~25 pills total was the visible scroll-stutter.
//

import SwiftUI

struct ModelManagerView: View {

    @EnvironmentObject private var downloadManager: ModelDownloadManager
    @EnvironmentObject private var selectionStore: ModelSelectionStore
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, the matching capability tab opens selected.
    var focusCapability: TTSCapability?

    @State private var selectedTab: TTSCapability
    @State private var snapshotPendingDelete: ModelSnapshot?

    init(focusCapability: TTSCapability? = nil) {
        self.focusCapability = focusCapability
        _selectedTab = State(initialValue: focusCapability ?? .customVoice)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                ForEach(TTSCapability.allCases, id: \.self) { capability in
                    capabilityPane(capability)
                        .tabItem {
                            Label(capability.displayName,
                                  systemImage: tabIcon(for: capability))
                        }
                        .tag(capability)
                }
            }
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
                Text("This frees \(DiskSpace.format(downloadManager.snapshotDiskUsage[snapshot] ?? 0)) on this device. You can re-download anytime. If this was your active variant, you'll be prompted to pick another.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 680, minHeight: 560)
        #endif
    }

    // MARK: - Tab content

    @ViewBuilder
    private func capabilityPane(_ capability: TTSCapability) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                introCard(for: capability)

                ForEach(variantBuckets(for: capability), id: \.id) { bucket in
                    variantCard(capability: capability, bucket: bucket)
                }

                storageFooter
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
    }

    /// Each variant card is built fresh on every parent re-render. It only
    /// takes plain values — SwiftUI can skip re-laying-out cards whose
    /// matrix slice didn't move.
    @ViewBuilder
    private func variantCard(capability: TTSCapability, bucket: VariantBucket) -> some View {
        let candidates = bucket.candidates
        let activeForCapability = selectionStore.selected(for: capability)
        VariantCard(
            capability: capability,
            family: bucket.family,
            snapshotCapability: bucket.snapshotCapability,
            candidates: candidates,
            states: candidates.reduce(into: [:]) { $0[$1] = downloadManager.snapshotStates[$1] ?? .absent },
            diskUsages: candidates.reduce(into: [:]) { $0[$1] = downloadManager.snapshotDiskUsage[$1] ?? 0 },
            activeSnapshot: activeForCapability,
            onDownload: { downloadManager.startDownload(of: $0) },
            onRetry: { downloadManager.retry($0) },
            onDelete: { snapshotPendingDelete = $0 },
            onSetActive: { selectionStore.select($0, for: capability) }
        )
    }

    @ViewBuilder
    private func introCard(for capability: TTSCapability) -> some View {
        let active = selectionStore.selected(for: capability)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(capability.displayName)
                        .font(.title3.bold())
                    Text(capabilityBlurb(capability))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
            }

            if let active, ModelDownloadManager.isInstalled(active) {
                Label {
                    Text("Active: ") +
                    Text("\(active.family.displayName) · \(active.precision.displayName)").fontWeight(.semibold)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .foregroundStyle(.green)
                .font(.caption)
            } else {
                Label("No variant selected — pick one below to use this capability.",
                      systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
    }

    private var storageFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Storage", systemImage: "internaldrive")
                    .font(.headline)
                Spacer()
            }
            HStack {
                Text("Total on disk")
                Spacer()
                Text(DiskSpace.format(totalBytes))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Installed variants")
                Spacer()
                Text("\(installedCount) of \(ModelSnapshot.allCases.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("Heads-up: 4-bit and 5-bit tiers can audibly degrade prosody for TTS. Listen before relying on them; bf16 is the reference precision.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Helpers

    private func tabIcon(for capability: TTSCapability) -> String {
        switch capability {
        case .customVoice: return "person.wave.2"
        case .voiceClone:  return "mic.badge.plus"
        case .voiceDesign: return "sparkles"
        }
    }

    private func capabilityBlurb(_ capability: TTSCapability) -> String {
        switch capability {
        case .customVoice:
            return "Built-in preset speakers (Vivian, Ryan, …). Base variants also cover voice cloning, so picking one here can satisfy two tabs at once."
        case .voiceClone:
            return "Clone any voice from a 3-second reference clip. 1.7B captures more nuance; 0.6B is faster and uses ~half the disk."
        case .voiceDesign:
            return "Generate a brand-new voice from a free-form description. Only published at 1.7B."
        }
    }

    /// Bucket the snapshots for a tab into one card per
    /// (family, snapshotCapability). Stable, deterministic order:
    ///  1.7B before 0.6B; Base before CustomVoice (since Base is the more
    ///  capable model in the customVoice tab).
    private func variantBuckets(for capability: TTSCapability) -> [VariantBucket] {
        let snaps = capability.compatibleSnapshots
        var buckets: [VariantBucket] = []
        for family in [ModelFamily.b17, .b06] {
            for snapCap in [SnapshotCapability.base, .customVoice, .voiceDesign] {
                let candidates = snaps
                    .filter { $0.family == family && $0.capability == snapCap }
                    .sorted { $0.precision.qualityRank > $1.precision.qualityRank }
                guard !candidates.isEmpty else { continue }
                buckets.append(VariantBucket(family: family,
                                             snapshotCapability: snapCap,
                                             candidates: candidates))
            }
        }
        return buckets
    }

    private var totalBytes: Int64 {
        downloadManager.snapshotDiskUsage.values.reduce(0, +)
    }

    private var installedCount: Int {
        downloadManager.snapshotStates.values.filter { $0.isInstalled }.count
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { snapshotPendingDelete != nil },
            set: { if !$0 { snapshotPendingDelete = nil } }
        )
    }
}

// MARK: - Bucket

private struct VariantBucket: Identifiable, Equatable {
    let family: ModelFamily
    let snapshotCapability: SnapshotCapability
    let candidates: [ModelSnapshot]
    var id: String { "\(family.rawValue)/\(snapshotCapability.rawValue)" }
}

// MARK: - Variant card

/// One Liquid-Glass card per (family, snapshotCapability). Hosts a
/// precision pill row; the body below shows the focused precision's status
/// and actions. Takes plain values rather than ObservableObjects so
/// SwiftUI can short-circuit re-renders during high-frequency download
/// progress updates.
private struct VariantCard: View, Equatable {

    let capability: TTSCapability
    let family: ModelFamily
    let snapshotCapability: SnapshotCapability
    let candidates: [ModelSnapshot]
    let states: [ModelSnapshot: SnapshotInstallState]
    let diskUsages: [ModelSnapshot: Int64]
    let activeSnapshot: ModelSnapshot?
    let onDownload: (ModelSnapshot) -> Void
    let onRetry: (ModelSnapshot) -> Void
    let onDelete: (ModelSnapshot) -> Void
    let onSetActive: (ModelSnapshot) -> Void

    @State private var focusedPrecision: ModelPrecision?

    static func == (lhs: VariantCard, rhs: VariantCard) -> Bool {
        lhs.capability == rhs.capability &&
        lhs.family == rhs.family &&
        lhs.snapshotCapability == rhs.snapshotCapability &&
        lhs.candidates == rhs.candidates &&
        lhs.states == rhs.states &&
        lhs.diskUsages == rhs.diskUsages &&
        lhs.activeSnapshot == rhs.activeSnapshot
    }

    private var resolvedFocus: ModelPrecision {
        if let focusedPrecision, candidates.contains(where: { $0.precision == focusedPrecision }) {
            return focusedPrecision
        }
        // Default focus: the user's active precision if it lives in this
        // bucket, otherwise the highest quality available.
        if let active = activeSnapshot,
           active.family == family,
           active.capability == snapshotCapability,
           candidates.contains(where: { $0.precision == active.precision }) {
            return active.precision
        }
        return candidates.first?.precision ?? .bf16
    }

    private var currentSnapshot: ModelSnapshot {
        candidates.first { $0.precision == resolvedFocus }
            ?? candidates.first
            ?? ModelSnapshot(family: family, capability: snapshotCapability, precision: .bf16)
    }

    var body: some View {
        let snapshot = currentSnapshot
        let state = states[snapshot] ?? .absent
        let usage = diskUsages[snapshot] ?? 0
        let isActive = activeSnapshot == snapshot

        VStack(alignment: .leading, spacing: 14) {
            header(isActive: isActive)
            precisionPills
            details(snapshot: snapshot, state: state, diskUsage: usage, isActive: isActive)

            if case .downloading(let progress, let file, let bps, let eta) = state {
                progressStrip(progress: progress, file: file, bps: bps, eta: eta)
            }

            if case .failed(let message) = state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Pieces

    private func header(isActive: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(family.displayName)
                        .font(.title3.bold())
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(snapshotCapability.displayName)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(coversBlurb)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    /// Cheap pill picker — a capsule per precision with a tinted background
    /// when focused. No per-pill `.glassEffect` (the parent card already
    /// renders glass; stacking another ~25 glass surfaces was the scroll
    /// stutter the user hit).
    private var precisionPills: some View {
        let focus = resolvedFocus
        return HStack(spacing: 6) {
            ForEach(candidates, id: \.id) { candidate in
                PrecisionPill(
                    precision: candidate.precision,
                    isFocused: candidate.precision == focus,
                    isInstalled: states[candidate]?.isInstalled ?? false,
                    onTap: { focusedPrecision = candidate.precision }
                )
            }
            Spacer(minLength: 0)
        }
    }

    private func details(snapshot: ModelSnapshot,
                         state: SnapshotInstallState,
                         diskUsage: Int64,
                         isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.precision.displayName)
                    .font(.headline)
                Spacer()
                statusBadge(for: state)
            }

            Text(snapshot.precision.qualityHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Label(sizeText(state: state, diskUsage: diskUsage, snapshot: snapshot),
                      systemImage: "internaldrive")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                actionButtons(snapshot: snapshot, state: state, isActive: isActive)
            }
        }
    }

    private func progressStrip(progress: Double, file: String, bps: Double, eta: Double?) -> some View {
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

    @ViewBuilder
    private func actionButtons(snapshot: ModelSnapshot,
                               state: SnapshotInstallState,
                               isActive: Bool) -> some View {
        switch state {
        case .absent:
            Button("Download") { onDownload(snapshot) }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .help("Fetch this variant from Hugging Face. Stays on this device.")

        case .failed:
            Button("Retry") { onRetry(snapshot) }
                .buttonStyle(.glass)
                .controlSize(.small)

        case .downloading:
            Button("Downloading…") {}
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(true)

        case .installed:
            HStack(spacing: 8) {
                if !isActive {
                    Button("Use this") { onSetActive(snapshot) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                        .help("Make this the active variant for \(capability.displayName).")
                }
                Button(role: .destructive) {
                    onDelete(snapshot)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Remove this variant and free disk space.")
            }

        case .checking:
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func statusBadge(for state: SnapshotInstallState) -> some View {
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
        case .absent:
            Label("Available", systemImage: "icloud.and.arrow.down")
                .foregroundStyle(.tertiary)
                .font(.caption)
                .labelStyle(.titleAndIcon)
        case .checking:
            EmptyView()
        }
    }

    private func sizeText(state: SnapshotInstallState,
                          diskUsage: Int64,
                          snapshot: ModelSnapshot) -> String {
        if state.isInstalled, diskUsage > 0 {
            return DiskSpace.format(diskUsage) + " on disk"
        }
        return "~\(DiskSpace.format(snapshot.approxBytes)) download"
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

    /// "Voice Cloning + Preset Voices" / "Preset Voices" / "Voice Design"
    /// — explains what tabs this card's snapshot covers, so the user knows
    /// when picking Base in the customVoice tab also satisfies the Clone
    /// tab.
    private var coversBlurb: String {
        switch snapshotCapability {
        case .base:        return "Covers Voice Cloning + Preset Voices"
        case .customVoice: return "Preset Voices only"
        case .voiceDesign: return "Voice Design only"
        }
    }
}

// MARK: - Precision pill

/// Cheap, glass-adjacent capsule. Selected pill uses the accent tint at
/// reduced opacity; idle pills use a thin material so they read as part
/// of the glass card without each carrying their own glass surface.
private struct PrecisionPill: View {
    let precision: ModelPrecision
    let isFocused: Bool
    let isInstalled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Text(precision.displayName)
                    .font(.caption.weight(isFocused ? .semibold : .regular))
                if isInstalled {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if isFocused {
                    Capsule(style: .continuous)
                        .fill(.tint.opacity(0.25))
                        .overlay(Capsule(style: .continuous).strokeBorder(.tint.opacity(0.6), lineWidth: 1))
                } else {
                    Capsule(style: .continuous)
                        .fill(.thinMaterial)
                        .overlay(Capsule(style: .continuous).strokeBorder(.separator.opacity(0.3), lineWidth: 0.5))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(precision.displayName) precision\(isInstalled ? ", installed" : "")")
    }
}

#Preview {
    ModelManagerView(focusCapability: .voiceClone)
        .environmentObject(ModelDownloadManager())
        .environmentObject(ModelSelectionStore())
}
