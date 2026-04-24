//
//  ModelDownloadManager.swift
//  VoiceClone
//

import Foundation

// MARK: - Model manifest

private struct ModelFile {
    let relativePath: String   // path inside MLXModels/ dir
    let downloadURL: String
    let expectedBytes: Int64
}

private let kModelManifest: [ModelFile] = [
    ModelFile(
        relativePath: "Qwen3TTS_FP16/talker_config.json",
        downloadURL: "https://huggingface.co/Qwen/Qwen3-TTS-0.6B/resolve/main/talker_config.json",
        expectedBytes: 4_096
    ),
    ModelFile(
        relativePath: "Qwen3TTS_FP16/talker_weights.safetensors",
        downloadURL: "https://huggingface.co/Qwen/Qwen3-TTS-0.6B/resolve/main/talker_weights.safetensors",
        expectedBytes: 3_600_000_000
    ),
    ModelFile(
        relativePath: "Qwen3TTS_Decoder/decoder_config.json",
        downloadURL: "https://huggingface.co/Qwen/Qwen3-TTS-0.6B/resolve/main/decoder_config.json",
        expectedBytes: 4_096
    ),
    ModelFile(
        relativePath: "Qwen3TTS_Decoder/decoder_weights.safetensors",
        downloadURL: "https://huggingface.co/Qwen/Qwen3-TTS-0.6B/resolve/main/decoder_weights.safetensors",
        expectedBytes: 436_000_000
    ),
]

// MARK: - Download state

enum ModelDownloadState: Equatable {
    case checking
    case ready
    case downloading(file: String, progress: Double, overallProgress: Double)
    case failed(String)

    static func == (lhs: ModelDownloadState, rhs: ModelDownloadState) -> Bool {
        switch (lhs, rhs) {
        case (.checking, .checking), (.ready, .ready): return true
        case (.downloading(let lf, let lp, let lo), .downloading(let rf, let rp, let ro)):
            return lf == rf && lp == rp && lo == ro
        case (.failed(let l), .failed(let r)): return l == r
        default: return false
        }
    }

    var isReady: Bool { self == .ready }
}

// MARK: - Manager

@MainActor
final class ModelDownloadManager: NSObject, ObservableObject {

    @Published private(set) var state: ModelDownloadState = .checking

    private var urlSession: URLSession?
    private var activeTasks: [URLSessionDownloadTask] = []
    private var pendingFiles: [ModelFile] = []
    private var completedCount = 0

    override init() {
        super.init()
        Task { await checkAndDownloadIfNeeded() }
    }

    // MARK: - Public

    func retry() {
        Task { await checkAndDownloadIfNeeded() }
    }

    // MARK: - Root directory

    static var modelsDirectory: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VoiceClone/MLXModels", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MLXModels", isDirectory: true)
        #endif
    }

    // MARK: - Check

    private func checkAndDownloadIfNeeded() async {
        state = .checking
        let missing = kModelManifest.filter { !fileExists($0) }
        if missing.isEmpty {
            state = .ready
        } else {
            await downloadFiles(missing)
        }
    }

    private func fileExists(_ file: ModelFile) -> Bool {
        let url = Self.modelsDirectory.appendingPathComponent(file.relativePath)
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Download

    private func downloadFiles(_ files: [ModelFile]) async {
        pendingFiles = files
        completedCount = 0

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        for file in files {
            guard let url = URL(string: file.downloadURL) else { continue }
            let task = urlSession!.downloadTask(with: url)
            task.taskDescription = file.relativePath
            activeTasks.append(task)
            task.resume()
        }

        // Wait for all tasks
        for task in activeTasks {
            _ = await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                task.resume()
                cont.resume()
            }
        }
    }

    private func finishDownload(task: URLSessionDownloadTask, location: URL) {
        guard let relativePath = task.taskDescription else { return }
        let destination = Self.modelsDirectory.appendingPathComponent(relativePath)

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            state = .failed("Failed to save \(relativePath): \(error.localizedDescription)")
            return
        }

        completedCount += 1
        if completedCount == pendingFiles.count {
            state = .ready
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloadManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        Task { @MainActor in
            self.finishDownload(task: downloadTask, location: location)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fileProgress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0

        let fileName = downloadTask.taskDescription ?? ""

        Task { @MainActor in
            let overall = (Double(self.completedCount) + fileProgress) / Double(self.pendingFiles.count)
            self.state = .downloading(file: fileName, progress: fileProgress, overallProgress: overall)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor in
            self.state = .failed(error.localizedDescription)
        }
    }
}
