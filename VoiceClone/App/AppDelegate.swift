//
//  AppDelegate.swift
//  VoiceClone
//

#if os(iOS)
import UIKit
import AVFoundation

/// iOS app delegate. Handles background lifecycle for the audio pipeline:
///   • On `applicationDidEnterBackground`, deactivate the audio session and
///     post `.appWillBackground` so view models can stop active synthesis
///     and save partial state.
///   • On `applicationWillEnterForeground`, post `.appDidForeground` so
///     view models can re-arm the audio session.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppLog.info("iOS app launched.", "app")
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        AppLog.info("App entered background — deactivating audio session.", "app")
        // Stop being audible in the background; we don't claim background audio.
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        NotificationCenter.default.post(name: .appWillBackground, object: nil)
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        AppLog.info("App returning to foreground.", "app")
        NotificationCenter.default.post(name: .appDidForeground, object: nil)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppLog.info("App terminating.", "app")
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        AppLog.warning("Memory warning received — clearing GPU cache.", "app")
        NotificationCenter.default.post(name: .appMemoryPressure, object: nil)
    }
}

extension Notification.Name {
    static let appWillBackground = Notification.Name("VoiceClone.appWillBackground")
    static let appDidForeground  = Notification.Name("VoiceClone.appDidForeground")
    static let appMemoryPressure = Notification.Name("VoiceClone.appMemoryPressure")
}
#endif
