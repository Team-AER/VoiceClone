//
//  SaveVoiceSheet.swift
//  PolyJuiceVoice
//
//  Modal "name this voice" prompt shared by the Design and Clone tabs.
//  Liquid Glass styling to match the rest of the app — drops the macOS
//  `Form` chrome (which was rendering the placeholder as a leading label
//  outside the field).
//

import SwiftUI

struct SaveVoiceSheet: View {

    let title: String
    let placeholder: String
    @Binding var name: String
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.bold())
                Text("Saved voices show up in the Speak tab's voice picker.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(title: "Voice name")
                GlassTextField(text: $name,
                               prompt: LocalizedStringKey(placeholder))
                    .focused($fieldFocused)
                    .onSubmit {
                        if isValid { onSave() }
                    }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(!isValid)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460)
        #endif
        .background {
            // Sheet background is provided by the system; we just need the
            // content to read as glassy. The text field carries its own
            // glass surface; everything else sits flat on the sheet.
            Color.clear
        }
        .task { fieldFocused = true }
    }
}

#Preview {
    @Previewable @State var name = ""
    return SaveVoiceSheet(title: "Save cloned voice",
                          placeholder: "e.g. My voice",
                          name: $name) {}
}
