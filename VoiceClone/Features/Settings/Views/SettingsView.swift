//
//  SettingsView.swift
//  VoiceClone
//
//  Single-stop preferences screen. Holds the entry points for Model Storage,
//  Microphone permission, Debug Log, and About — every "system housekeeping"
//  surface the user might need.
//

import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var downloadManager: ModelDownloadManager
    @State private var showingModelManager = false

    var body: some View {
        NavigationStack {
            List {
                modelsSection
                permissionsSection
                diagnosticsSection
                aboutSection
            }
            #if os(macOS)
            .listStyle(.inset)
            #else
            .listStyle(.insetGrouped)
            #endif
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(isPresented: $showingModelManager) {
                ModelManagerView()
                    .environmentObject(downloadManager)
            }
        }
    }

    // MARK: - Sections

    private var modelsSection: some View {
        Section {
            Button {
                showingModelManager = true
            } label: {
                rowLabel(title: "Models",
                         subtitle: modelStorageSubtitle,
                         icon: "internaldrive",
                         tint: .blue)
            }

            HStack {
                Label("Disk usage", systemImage: "chart.pie")
                Spacer()
                Text(totalDiskUsage)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Storage")
        }
    }

    private var permissionsSection: some View {
        Section {
            Button {
                SystemSettings.openMicrophoneSettings()
            } label: {
                rowLabel(title: "Microphone access",
                         subtitle: "Open System Settings to grant permission for Clone.",
                         icon: "mic",
                         tint: .red)
            }
        } header: {
            Text("Permissions")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                DebugLogView()
            } label: {
                rowLabel(title: "Debug log",
                         subtitle: "Last 500 events, shareable as plain text.",
                         icon: "ladybug",
                         tint: .orange)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Share the log when reporting an issue. It contains no personal data — only timing, model, and audio events.")
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutView()
            } label: {
                rowLabel(title: "About",
                         subtitle: "Version, attribution, and privacy.",
                         icon: "info.circle",
                         tint: .gray)
            }
        }
    }

    // MARK: - Helpers

    private var modelStorageSubtitle: String {
        let installed = ModelSnapshot.allCases.filter { downloadManager.snapshotStates[$0]?.isInstalled == true }
        if installed.isEmpty { return "No models installed." }
        return "\(installed.count) installed · tap to manage."
    }

    private var totalDiskUsage: String {
        let total = downloadManager.snapshotDiskUsage.values.reduce(Int64(0), +)
        return DiskSpace.format(total)
    }

    private func rowLabel(title: String, subtitle: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: .rect(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(ModelDownloadManager())
}
