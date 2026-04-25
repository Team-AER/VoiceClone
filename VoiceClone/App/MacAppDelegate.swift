//
//  MacAppDelegate.swift
//  VoiceClone
//

#if os(macOS)
import AppKit

final class MacAppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.info("macOS app launched.", "app")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Quit when the main window closes — single-window app.
        true
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Window lost focus (Cmd-Tab, Mission Control). Don't pause audio
        // here — the user expects continued playback when switching apps on
        // macOS. Just log so the diagnostics screen has the trail.
        AppLog.debug("App resigned active.", "app")
    }

    func applicationDidReceiveMemoryWarning(_ application: NSApplication) {
        // macOS doesn't fire memory warnings the same way iOS does, but we
        // expose the same notification so view models can react uniformly.
        NotificationCenter.default.post(name: .appMemoryPressure, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.info("App terminating.", "app")
    }
}

// macOS mirror of the iOS notification names so cross-platform code can
// observe a single set of names.
extension Notification.Name {
    static let appMemoryPressure = Notification.Name("VoiceClone.appMemoryPressure")
    static let appWillBackground = Notification.Name("VoiceClone.appWillBackground")
    static let appDidForeground  = Notification.Name("VoiceClone.appDidForeground")
}
#endif
