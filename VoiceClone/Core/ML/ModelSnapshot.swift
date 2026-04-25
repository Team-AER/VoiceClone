//
//  ModelSnapshot.swift
//  VoiceClone
//
//  Static registry of every Qwen3-TTS variant the app knows how to download
//  and run. One snapshot per HuggingFace repo, each backing one or more TTS
//  capabilities.
//

import Foundation

/// One downloadable Qwen3-TTS model variant.
///
/// The `rawValue` is the on-disk directory name under
/// `ModelDownloadManager.modelsDirectory`.
enum ModelSnapshot: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 0.6B model with preset speakers (Vivian/Ryan/etc.) — also accepts an
    /// `instruct` overlay for emotion/style modulation on top of a preset.
    case customVoice = "Qwen3TTS-CustomVoice-bf16"
    /// 0.6B model that supports voice cloning (in-context learning from a
    /// reference audio + transcript) and the same preset speakers as
    /// CustomVoice. Ships the SeanetEncoder weights CustomVoice does not.
    case base        = "Qwen3TTS-Base-bf16"
    /// 1.7B model that synthesizes a brand-new voice from a free-form
    /// description with no preset speaker. The biggest of the three.
    case voiceDesign = "Qwen3TTS-VoiceDesign-bf16"

    var id: String { rawValue }

    // MARK: - User-facing metadata

    var displayName: String {
        switch self {
        case .customVoice: return "Preset Voices (0.6B)"
        case .base:        return "Voice Cloning (0.6B)"
        case .voiceDesign: return "Voice Design (1.7B)"
        }
    }

    var summary: String {
        switch self {
        case .customVoice:
            return "Built-in speakers with optional emotion/style overlay. Required for the Speak tab."
        case .base:
            return "Clone a voice from a short recording you provide. Required for the Clone tab."
        case .voiceDesign:
            return "Generate a brand-new voice from a free-form description. Required for the Design tab."
        }
    }

    var capabilities: Set<TTSCapability> {
        switch self {
        case .customVoice: return [.customVoice]
        case .base:        return [.voiceClone, .customVoice]   // Base also does presets
        case .voiceDesign: return [.voiceDesign]
        }
    }

    /// CustomVoice is the gate snapshot — without it the app has nothing to do
    /// at all, so the launch UI blocks on it. Other snapshots are opt-in
    /// downloads triggered from the Model Manager or per-tab CTAs.
    var isRequired: Bool { self == .customVoice }

    /// Approximate total bytes for progress UI; doesn't have to be exact.
    var approxBytes: Int64 {
        manifest.reduce(0) { $0 + $1.expectedBytes }
    }

    // MARK: - HF repo & manifest

    /// The HF repo that hosts this snapshot's weights & configs.
    var hfRepo: String {
        switch self {
        case .customVoice: return "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16"
        case .base:        return "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16"
        case .voiceDesign: return "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16"
        }
    }

    /// `tokenizer.json` is missing from every mlx-community Qwen3-TTS snapshot;
    /// `AutoTokenizer.from(modelFolder:)` requires it. Pull it from the
    /// matching size of the upstream Qwen3 LLM (same vocab/merges).
    private var tokenizerJsonURL: String {
        switch self {
        case .customVoice, .base:
            return "https://huggingface.co/Qwen/Qwen3-0.6B/resolve/main/tokenizer.json"
        case .voiceDesign:
            return "https://huggingface.co/Qwen/Qwen3-1.7B/resolve/main/tokenizer.json"
        }
    }

    /// Approximate size of the main `model.safetensors` weight file. Used by
    /// `manifest` only — actual size on disk comes from the server.
    private var modelWeightBytes: Int64 {
        switch self {
        case .customVoice: return 1_811_626_550
        case .base:        return 1_829_344_448
        case .voiceDesign: return 3_833_402_589
        }
    }

    var manifest: [ModelFile] {
        let base = "https://huggingface.co/\(hfRepo)/resolve/main"
        return [
            ModelFile(relativePath: "config.json",
                      downloadURL: "\(base)/config.json",
                      expectedBytes: 5_853),
            ModelFile(relativePath: "generation_config.json",
                      downloadURL: "\(base)/generation_config.json",
                      expectedBytes: 245),
            ModelFile(relativePath: "preprocessor_config.json",
                      downloadURL: "\(base)/preprocessor_config.json",
                      expectedBytes: 127),
            ModelFile(relativePath: "model.safetensors",
                      downloadURL: "\(base)/model.safetensors",
                      expectedBytes: modelWeightBytes),
            ModelFile(relativePath: "model.safetensors.index.json",
                      downloadURL: "\(base)/model.safetensors.index.json",
                      expectedBytes: 32_289),
            ModelFile(relativePath: "tokenizer_config.json",
                      downloadURL: "\(base)/tokenizer_config.json",
                      expectedBytes: 7_344),
            ModelFile(relativePath: "tokenizer.json",
                      downloadURL: tokenizerJsonURL,
                      expectedBytes: 11_422_654),
            ModelFile(relativePath: "vocab.json",
                      downloadURL: "\(base)/vocab.json",
                      expectedBytes: 2_776_833),
            ModelFile(relativePath: "merges.txt",
                      downloadURL: "\(base)/merges.txt",
                      expectedBytes: 1_671_839),
            ModelFile(relativePath: "speech_tokenizer/config.json",
                      downloadURL: "\(base)/speech_tokenizer/config.json",
                      expectedBytes: 2_336),
            ModelFile(relativePath: "speech_tokenizer/configuration.json",
                      downloadURL: "\(base)/speech_tokenizer/configuration.json",
                      expectedBytes: 76),
            ModelFile(relativePath: "speech_tokenizer/preprocessor_config.json",
                      downloadURL: "\(base)/speech_tokenizer/preprocessor_config.json",
                      expectedBytes: 234),
            ModelFile(relativePath: "speech_tokenizer/model.safetensors",
                      downloadURL: "\(base)/speech_tokenizer/model.safetensors",
                      expectedBytes: 682_293_092),
        ]
    }
}

/// A single downloadable file inside a snapshot.
struct ModelFile: Sendable {
    /// Path inside the snapshot directory (relative).
    let relativePath: String
    /// Remote URL to fetch from.
    let downloadURL: String
    /// Expected byte count (for progress UI; approximate is fine).
    let expectedBytes: Int64
}
