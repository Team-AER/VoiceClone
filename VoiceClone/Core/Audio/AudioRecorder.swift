//
//  AudioRecorder.swift
//  VoiceClone
//

import AVFoundation
import Foundation

/// Records audio for voice cloning reference
@MainActor
final class AudioRecorder: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0

    private var audioRecorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private let fileManager = FileManager.default

    var minimumDuration: TimeInterval { 3.0 }

    func startRecording() async throws -> URL {
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
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
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
}

enum RecordingError: LocalizedError {
    case permissionDenied
    case notRecording
    case tooShort(minimum: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access denied"
        case .notRecording:
            return "Not currently recording"
        case .tooShort(let minimum):
            return "Recording must be at least \(Int(minimum)) seconds"
        }
    }
}
