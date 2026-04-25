//
//  AppDelegate.swift
//  PolyJuiceVoice
//

#if os(iOS)
import UIKit
import AVFoundation
import MetricKit
@preconcurrency import MLX

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
        MXMetricManager.shared.add(self)
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

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Store the handler. ModelDownloadManager calls it from
        // urlSessionDidFinishEvents(forBackgroundURLSession:) once all
        // pending background-transfer events have been delivered.
        ModelDownloadManager.pendingBackgroundCompletion = completionHandler
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        AppLog.warning("Memory warning received — clearing GPU cache.", "app")
        // Clear the MLX buffer pool synchronously here, on the main thread.
        // The notification handler in MLXTTSService hops to a Task @MainActor,
        // which is too slow — jetsam fires synchronously and the process is
        // dead before the task runs. Clearing here is the only reliable window.
        GPU.clearCache()
        NotificationCenter.default.post(name: .appMemoryPressure, object: nil)
    }
}

// MARK: - MetricKit subscriber

extension AppDelegate: MXMetricManagerSubscriber {

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            AppLog.info("MetricKit metrics received: \(payload.timeStampBegin) – \(payload.timeStampEnd)", "metrics")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            if let crashes = payload.crashDiagnostics, !crashes.isEmpty {
                AppLog.error("MetricKit: \(crashes.count) crash diagnostic(s) from previous session.", "metrics")
            }
            if let hangs = payload.hangDiagnostics, !hangs.isEmpty {
                AppLog.warning("MetricKit: \(hangs.count) hang diagnostic(s) from previous session.", "metrics")
            }
            if let cpuExceptions = payload.cpuExceptionDiagnostics, !cpuExceptions.isEmpty {
                AppLog.warning("MetricKit: \(cpuExceptions.count) CPU exception(s) from previous session.", "metrics")
            }
        }
    }
}

extension Notification.Name {
    static let appWillBackground = Notification.Name("PolyJuiceVoice.appWillBackground")
    static let appDidForeground  = Notification.Name("PolyJuiceVoice.appDidForeground")
    static let appMemoryPressure = Notification.Name("PolyJuiceVoice.appMemoryPressure")
}
#endif
