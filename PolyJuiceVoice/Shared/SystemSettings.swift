//
//  SystemSettings.swift
//  PolyJuiceVoice
//
//  Cross-platform deep link to the System Settings page where the user
//  can grant microphone permission. Used by the Clone tab error alert
//  when `RecordingError.permissionDenied` is surfaced.
//

import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum SystemSettings {

    /// Open the OS settings UI focused on the app's microphone permission
    /// page (best-effort; falls back to the general app settings page).
    static func openMicrophoneSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString),
           UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        // macOS Privacy & Security → Microphone deep link.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
