//
//  AudioRecorder.swift
//  PolyJuiceVoice
//

import AVFoundation
import Foundation

/// Records audio for voice cloning reference.
///
/// On iOS, listens for `AVAudioSession.interruptionNotification` and
/// cancels any in-flight recording when interrupted (phone call, Siri,
/// alarm). Recordings can't be cleanly resumed mid-take — the file would
/// stitch together silence — so we drop the partial recording and surface
/// `RecordingError.interrupted` so the UI prompts the user to retake.
@MainActor
final class AudioRecorder: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0
    /// Set to true when an audio-session interruption killed an in-flight
    /// recording. Cleared on the next `startRecording()`. View models can
    /// observe this to show a "your recording was interrupted" banner.
    @Published private(set) var wasInterrupted = false

    private var audioRecorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private let fileManager = FileManager.default
    private var interruptionObservers: [NSObjectProtocol] = []

    var minimumDuration: TimeInterval { 3.0 }

    init() {
        registerForInterruptions()
    }

    // No deinit-time observer cleanup: NotificationCenter.default holds
    // weak refs in iOS 9+/macOS 10.11+, so the observers detach automatically
    // when this object is deallocated. (Crossing actor isolation in deinit
    // is a Swift 6 error.)

    func startRecording() async throws -> URL {
        wasInterrupted = false
        try await requestMicrophonePermission()

        let url = tempRecordingURL()

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 24000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)
        #endif

        audioRecorder = try AVAudioRecorder(url: url, settings: settings)
        audioRecorder?.isMeteringEnabled = true
        audioRecorder?.record()

        isRecording = true
        startLevelMetering()

        return url
    }

    func stopRecording() throws -> (url: URL, duration: TimeInterval) {
        guard let recorder = audioRecorder else {
            throw RecordingError.notRecording
        }

        let duration = recorder.currentTime
        let url = recorder.url

        recorder.stop()
        audioRecorder = nil

        isRecording = false
        stopLevelMetering()

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif

        guard duration >= minimumDuration else {
            try? fileManager.removeItem(at: url)
            throw RecordingError.tooShort(minimum: minimumDuration)
        }

        return (url, duration)
    }

    func cancelRecording() {
        guard let recorder = audioRecorder else { return }

        recorder.stop()
        try? fileManager.removeItem(at: recorder.url)
        audioRecorder = nil

        isRecording = false
        stopLevelMetering()

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    // MARK: - Private

    private func requestMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw RecordingError.permissionDenied
            }
        case .denied, .restricted:
            throw RecordingError.permissionDenied
        @unknown default:
            throw RecordingError.permissionDenied
        }
    }

    private func tempRecordingURL() -> URL {
        let tempDir = fileManager.temporaryDirectory
        let filename = "recording_\(UUID().uuidString).wav"
        return tempDir.appendingPathComponent(filename)
    }

    private func startLevelMetering() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateLevels() }
        }
    }

    private func stopLevelMetering() {
        levelTimer?.invalidate()
        levelTimer = nil
        audioLevel = 0
        currentTime = 0
    }

    private func updateLevels() {
        guard let recorder = audioRecorder else { return }

        recorder.updateMeters()

        let level = recorder.averagePower(forChannel: 0)
        audioLevel = pow(10, level / 20)
        currentTime = recorder.currentTime
    }

    // MARK: - Interruptions

    private func registerForInterruptions() {
        #if os(iOS)
        // Notification isn't Sendable under Swift 6 strict concurrency, so
        // pull the primitive UInt off the userInfo synchronously here and
        // hand only that across the actor boundary.
        let observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                guard let self else { return }
                guard let raw = typeRaw,
                      let type = AVAudioSession.InterruptionType(rawValue: raw),
                      type == .began,
                      self.isRecording else { return }
                AppLog.warning("Recording interrupted — discarding partial take.", "audio")
                self.cancelRecording()
                self.wasInterrupted = true
            }
        }
        interruptionObservers.append(observer)
        #endif
    }
}

enum RecordingError: LocalizedError {
    case permissionDenied
    case notRecording
    case tooShort(minimum: TimeInterval)
    case interrupted

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access denied. Open Settings to grant permission."
        case .notRecording:
            return "Not currently recording"
        case .tooShort(let minimum):
            return "Recording must be at least \(Int(minimum)) seconds"
        case .interrupted:
            return "Recording was interrupted by another audio source. Please try again."
        }
    }
}
