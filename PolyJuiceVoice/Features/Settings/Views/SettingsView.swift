//
//  SettingsView.swift
//  PolyJuiceVoice
//
//  Single-stop preferences screen. Holds the entry points for Model Storage,
//  Microphone permission, Debug Log, and About.
//
//  Built as a ScrollView of glass cards (rather than a `List` of `Section`s)
//  because `.listStyle(.inset)` on macOS 26 renders `Button` rows and
//  `NavigationLink` rows with different chrome — producing visibly
//  inconsistent section spacing. Custom cards keep every row identical.
//

import AVFoundation
import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var downloadManager: ModelDownloadManager
    @ObservedObject private var iCloudSettings = ICloudSyncSettings.shared
    @State private var showingModelManager = false
    @State private var microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        NavigationStack {
            ScrollView {
                GlassEffectContainer(spacing: 18) {
                    VStack(alignment: .leading, spacing: 22) {
                        section(title: "iCloud Sync") {
                            VStack(spacing: 0) {
                                HStack(spacing: 14) {
                                    iconBadge("icloud", tint: .blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Sync across devices")
                                        Text("Voices sync privately via your iCloud account — no extra login beyond your Apple ID.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 8)
                                    Toggle("", isOn: iCloudToggleBinding)
                                        .labelsHidden()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)

                                if iCloudSettings.pendingRestart {
                                    Divider()
                                    HStack(spacing: 10) {
                                        Image(systemName: "arrow.clockwise.circle.fill")
                                            .foregroundStyle(.orange)
                                        Text("Restart the app to apply this change.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                }
                            }
                            .background(rowGroupSurface)
                        }

                        section(title: "Storage") {
                            VStack(spacing: 1) {
                                actionRow(
                                    title: "Models",
                                    subtitle: modelStorageSubtitle,
                                    icon: "internaldrive",
                                    tint: .blue,
                                    accessory: .chevron,
                                    action: { showingModelManager = true }
                                )
                                infoRow(
                                    title: "Disk usage",
                                    icon: "chart.pie",
                                    tint: .blue,
                                    trailing: totalDiskUsage
                                )
                            }
                            .background(rowGroupSurface)
                        }

                        section(title: "Permissions") {
                            microphonePermissionRow
                            .background(rowGroupSurface)
                        }

                        section(title: "Diagnostics") {
                            NavigationLink {
                                DebugLogView()
                            } label: {
                                rowContent(
                                    title: "Debug log",
                                    subtitle: "Last 500 events. Share when reporting an issue — no personal data, only timing & model events.",
                                    icon: "ladybug",
                                    tint: .orange,
                                    accessory: .chevron
                                )
                            }
                            .buttonStyle(.plain)
                            .background(rowGroupSurface)
                        }

                        section(title: "About") {
                            NavigationLink {
                                AboutView()
                            } label: {
                                rowContent(
                                    title: "About",
                                    subtitle: "Version, attribution, and privacy.",
                                    icon: "info.circle",
                                    tint: .gray,
                                    accessory: .chevron
                                )
                            }
                            .buttonStyle(.plain)
                            .background(rowGroupSurface)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings")
            .onAppear {
                refreshMicrophonePermissionStatus()
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(isPresented: $showingModelManager) {
                ModelManagerView()
                    .environmentObject(downloadManager)
            }
        }
    }

    // MARK: - Section chrome

    @ViewBuilder
    private func section<Content: View>(title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, 4)
            content()
        }
    }

    /// Liquid Glass surface that wraps each section's row(s). Stays
    /// identical regardless of whether the row is a `Button`,
    /// `NavigationLink`, or a passive info row — which was the source of
    /// the inset-list inconsistency.
    private var rowGroupSurface: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.separator.opacity(0.25), lineWidth: 0.5)
            )
    }

    // MARK: - Row variants

    private enum RowAccessory {
        case none
        case chevron
        case external
    }

    private func actionRow(title: String,
                           subtitle: String,
                           icon: String,
                           tint: Color,
                           accessory: RowAccessory,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            rowContent(title: title,
                       subtitle: subtitle,
                       icon: icon,
                       tint: tint,
                       accessory: accessory)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var microphonePermissionRow: some View {
        if canOpenMicrophoneSettings {
            actionRow(
                title: "Microphone access",
                subtitle: microphonePermissionSubtitle,
                icon: "mic",
                tint: .red,
                accessory: .external,
                action: { SystemSettings.openMicrophoneSettings() }
            )
        } else {
            rowContent(
                title: "Microphone access",
                subtitle: microphonePermissionSubtitle,
                icon: "mic",
                tint: .red,
                accessory: .none
            )
        }
    }

    private func infoRow(title: String,
                         icon: String,
                         tint: Color,
                         trailing: String) -> some View {
        HStack(spacing: 14) {
            iconBadge(icon, tint: tint)
            Text(title)
            Spacer()
            Text(trailing)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func rowContent(title: String,
                            subtitle: String,
                            icon: String,
                            tint: Color,
                            accessory: RowAccessory) -> some View {
        HStack(spacing: 14) {
            iconBadge(icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch accessory {
            case .none:
                EmptyView()
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            case .external:
                Image(systemName: "arrow.up.right.square")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func iconBadge(_ icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(tint.gradient, in: .rect(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }

    // MARK: - iCloud

    private var iCloudToggleBinding: Binding<Bool> {
        Binding(
            get: { iCloudSettings.isEnabled },
            set: { iCloudSettings.setEnabled($0) }
        )
    }

    // MARK: - Derived data

    private var modelStorageSubtitle: String {
        let installed = ModelSnapshot.allCases.filter { downloadManager.snapshotStates[$0]?.isInstalled == true }
        if installed.isEmpty { return "No models installed — tap to set up." }
        return "\(installed.count) installed · tap to manage variants."
    }

    private var totalDiskUsage: String {
        let total = downloadManager.snapshotDiskUsage.values.reduce(Int64(0), +)
        return DiskSpace.format(total)
    }

    private var canOpenMicrophoneSettings: Bool {
        microphoneAuthorizationStatus == .denied || microphoneAuthorizationStatus == .restricted
    }

    private var microphonePermissionSubtitle: String {
        switch microphoneAuthorizationStatus {
        case .authorized:
            return "Allowed for Clone recordings."
        case .notDetermined:
            return "Permission is requested when you start a reference recording."
        case .denied:
            return "Access is off. Open Settings to enable Clone recordings."
        case .restricted:
            return "Access is restricted. Open Settings to review microphone access."
        @unknown default:
            return "Permission is requested when you start a reference recording."
        }
    }

    private func refreshMicrophonePermissionStatus() {
        microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }
}

#Preview {
    SettingsView()
        .environmentObject(ModelDownloadManager())
}
