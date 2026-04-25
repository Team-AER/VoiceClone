//
//  MissingSnapshotPrompt.swift
//  PolyJuiceVoice
//
//  Inline CTA shown inside a feature tab when the user hasn't picked a model
//  for that tab's capability — or has, but the snapshot was deleted. Tapping
//  the action opens the Model Manager with the relevant capability section
//  in focus.
//

import SwiftUI

/// "You haven't set up a model for X. Open the Model Manager to download one."
struct MissingCapabilityPrompt: View {

    let capability: TTSCapability
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive.badge.icloud")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("\(capability.displayName) needs a model")
                .font(.headline)

            Text(blurb)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Model Manager", action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)

            Text(matrixHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var blurb: String {
        switch capability {
        case .customVoice:
            return "Pick a Preset Voices or Voice Cloning model to use the built-in speakers. Both 0.6B and 1.7B variants are available — the Manager lays out the trade-offs."
        case .voiceClone:
            return "Voice cloning needs a Base model. 0.6B is faster and smaller; 1.7B captures more nuance from a short reference clip."
        case .voiceDesign:
            return "Voice Design only ships at 1.7B. Pick a precision tier — bf16 for highest quality, lower bits to save disk."
        }
    }

    private var matrixHint: String {
        let count = capability.compatibleSnapshots.count
        return "\(count) variants available · downloaded once, run on-device."
    }
}

#Preview {
    VStack(spacing: 24) {
        MissingCapabilityPrompt(capability: .voiceClone) {}
        MissingCapabilityPrompt(capability: .voiceDesign) {}
    }
    .padding()
}
