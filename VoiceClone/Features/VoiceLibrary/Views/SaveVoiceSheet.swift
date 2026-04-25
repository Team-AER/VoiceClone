//
//  SaveVoiceSheet.swift
//  VoiceClone
//
//  Modal "name this voice" prompt shared by the Design and Clone tabs.
//

import SwiftUI

struct SaveVoiceSheet: View {

    let title: String
    let placeholder: String
    @Binding var name: String
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Voice name") {
                    TextField(placeholder, text: $name)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 180)
        #endif
    }
}

#Preview {
    @Previewable @State var name = ""
    return SaveVoiceSheet(title: "Save voice",
                          placeholder: "e.g. Calm narrator",
                          name: $name) {}
}
