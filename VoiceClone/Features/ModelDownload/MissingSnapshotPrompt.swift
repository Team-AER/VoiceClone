//
//  MissingSnapshotPrompt.swift
//  VoiceClone
//
//  Reusable inline CTA shown inside a feature tab when its required model
//  snapshot is not installed. Tapping the action opens `ModelManagerView`.
//

import SwiftUI

struct MissingSnapshotPrompt: View {

    let snapshot: ModelSnapshot
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text(snapshot.displayName)
                .font(.headline)

            Text(snapshot.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                Text(humanReadableSize)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)

            Button("Download \(humanReadableSize)…", action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var humanReadableSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: snapshot.approxBytes)
    }
}

#Preview {
    MissingSnapshotPrompt(snapshot: .base) {}
        .padding()
}
