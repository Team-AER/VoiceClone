//
//  ModelDownloadManager.swift
//  VoiceClone
//
//  Downloads pre-converted MLX weights from HuggingFace at first launch.
//  The target layout matches what the vendored Qwen3TTS package expects:
//  a single model directory with `config.json`, `*.safetensors`, tokenizer
//  files, and a `speech_tokenizer/` subdirectory.
//

import Foundation

// MARK: - Model manifest

private struct ModelFile {
    /// Path inside the managed model dir (relative).
    let relativePath: String
    /// Remote URL to fetch from.
    let downloadURL: String
    /// Expected byte count (for progress UI; approximate is fine).
    let expectedBytes: Int64
}

/// `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16` — a pre-converted MLX
/// snapshot that loads directly with `Qwen3TTSModel.fromPretrained`.
private let kModelRoot = "Qwen3TTS-CustomVoice-bf16"

private let kModelManifest: [ModelFile] = [
    ModelFile(relativePath: "config.json",
              downloadURL: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16/resolve/main/config.json",
              expectedBytes: 5_853),
    ModelFile(relativePath: "generation_config.json",
              downloadURL: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16/resolve/main/generation_config.json",
              expectedBytes: 245),
    ModelFile(relativePath: "preprocessor_config.json",
              downloadURL: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16/resolve/main/preprocessor_config.json",
              expectedBytes: 127),
    ModelFile(relativePath: "model.safetensors",
              downloadURL: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16/resolve/main/model.safetensors",
              expectedBytes: 1_811_626_550),
    ModelFile(relativePath: "model.safetensors.index.json",
              downloadURL: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16/resolve/main/model.safetensors.index.json",
              expectedBytes: 32_289),
    ModelFile(relativePath: "tokenizer_config.json",
              downloadURL: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16/resolve/main/tokenizer_config.json",
              expectedBytes: 7_344),
    // `tokenizer.json` is not in the CustomVoice snapshot but swift-transformers'
    // AutoTokenizer requires it. Qwen3-TTS reuses the Qwen3 LLM tokenizer, so we
    // fetch it from `Qwen/Qwen3-0.6B` — same vocab (151643) and merges (151387).
    ModelFile(relativePath: "tokenizer.json",
              downloadURL: "https://huggingface.co/Qwen/Qwen3-0.6B/resolve/main/tokenizer.json",
              expectedBytes: 11_422_654),
    ModelFile(relativePath: "vocab.json",
              downloadURL: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16/resolve/main/vocab.json",
              expectedBytes: 2_776_833),
    ModelFile(relativePath: "merges.txt",
              downloadURL: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16/resolve/main/merges.txt",
              expectedBytes: 1_671_839),
    ModelFile(relativePath: "speech_tokenizer/config.json",
              downloadURL: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16/resolve/main/speech_tokenizer/config.json",
              expectedBytes: 2_336),
    ModelFile(relativePath: "speech_tokenizer/configuration.json",
              downloadURL: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16/resolve/main/speech_tokenizer/configuration.json",
              expectedBytes: 76),
    ModelFile(relativePath: "speech_tokenizer/preprocessor_config.json",
              downloadURL: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16/resolve/main/speech_tokenizer/preprocessor_config.json",
              expectedBytes: 234),
    ModelFile(relativePath: "speech_tokenizer/model.safetensors",
              downloadURL: "https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16/resolve/main/speech_tokenizer/model.safetensors",
              expectedBytes: 682_293_092),
]

// MARK: - Download state

enum ModelDownloadState: Equatable {
    case checking
    case awaitingPermission
    case ready
    case downloading(file: String, progress: Double, overallProgress: Double)
    case failed(String)

    static func == (lhs: ModelDownloadState, rhs: ModelDownloadState) -> Bool {
        switch (lhs, rhs) {
        case (.checking, .checking), (.ready, .ready), (.awaitingPermission, .awaitingPermission): return true
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

    func startDownload() {
        let missing = kModelManifest.filter { !fileIsValid($0) }
        guard !missing.isEmpty else {
            state = .ready
            return
        }
        downloadFiles(missing)
    }

    func retry() {
        clearCorruptFiles()
        startDownload()
    }

    // MARK: - Paths

    /// Root directory that holds all managed TTS model files.
    /// nonisolated so delegate callbacks on background queues can use it.
    nonisolated static var modelsDirectory: URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VoiceClone/MLXModels", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MLXModels", isDirectory: true)
        #endif
    }

    /// Directory containing the single Qwen3-TTS model that the app uses.
    /// This is the path passed to `Qwen3TTSModel.fromPretrained`.
    nonisolated static var currentModelDirectory: URL {
        modelsDirectory.appendingPathComponent(kModelRoot, isDirectory: true)
    }

    /// `true` when every file required to run TTS is on disk.
    nonisolated static func areModelsAvailable() -> Bool {
        let fm = FileManager.default
        for file in kModelManifest {
            let url = currentModelDirectory.appendingPathComponent(file.relativePath)
            guard fm.fileExists(atPath: url.path) else { return false }
        }
        return true
    }

    // MARK: - Check

    private func checkAndDownloadIfNeeded() async {
        state = .checking
        let missing = kModelManifest.filter { !fileIsValid($0) }
        state = missing.isEmpty ? .ready : .awaitingPermission
    }

    /// A file is valid when it's on disk in the managed dir and passes a basic
    /// content sniff. We intentionally don't trust `expectedBytes` for equality
    /// because HF occasionally repacks files.
    private func fileIsValid(_ file: ModelFile) -> Bool {
        let url = Self.currentModelDirectory.appendingPathComponent(file.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return contentIsValid(at: url)
    }

    private func contentIsValid(at url: URL) -> Bool {
        switch url.pathExtension {
        case "json":
            guard let data = try? Data(contentsOf: url),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                return false
            }
            return true
        case "safetensors":
            return safetensorsHeaderIsValid(at: url)
        default:
            return true
        }
    }

    /// Reads the 8-byte safetensors header prefix and checks the claimed JSON
    /// metadata length is in a sane range.
    private func safetensorsHeaderIsValid(at url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let prefix = fh.readData(ofLength: 8)
        guard prefix.count == 8 else { return false }
        let headerLen = prefix.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        return headerLen > 0 && headerLen < 100_000_000
    }

    // MARK: - Corrupt file cleanup

    private func clearCorruptFiles() {
        let fm = FileManager.default
        for file in kModelManifest {
            let url = Self.currentModelDirectory.appendingPathComponent(file.relativePath)
            guard fm.fileExists(atPath: url.path) else { continue }
            if !contentIsValid(at: url) {
                try? fm.removeItem(at: url)
                print("⚠️ Removed corrupt cached file: \(file.relativePath)")
            }
        }
    }

    // MARK: - Download

    private func downloadFiles(_ files: [ModelFile]) {
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
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloadManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
            let code = httpResponse.statusCode
            let path = downloadTask.taskDescription ?? "unknown"
            Task { @MainActor in
                self.state = .failed("Server returned HTTP \(code) for \(path)")
            }
            return
        }

        guard let relativePath = downloadTask.taskDescription else { return }
        let destination = ModelDownloadManager.currentModelDirectory.appendingPathComponent(relativePath)

        // Must move synchronously — URLSession deletes the temp file when this returns.
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
            let message = error.localizedDescription
            Task { @MainActor in
                self.state = .failed("Failed to save \(relativePath): \(message)")
            }
            return
        }

        // Reject HTML error pages masquerading as JSON.
        if destination.pathExtension == "json" {
            if let data = try? Data(contentsOf: destination),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                // Valid JSON.
            } else {
                try? FileManager.default.removeItem(at: destination)
                Task { @MainActor in
                    self.state = .failed(
                        "Downloaded \(relativePath) is not valid JSON — the server may have returned an error page."
                    )
                }
                return
            }
        }

        Task { @MainActor in
            self.completedCount += 1
            if self.completedCount == self.pendingFiles.count {
                self.state = .ready
            }
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
