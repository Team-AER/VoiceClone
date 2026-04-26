//
//  ModelSnapshot.swift
//  PolyJuiceVoice
//
//  Static registry of every Qwen3-TTS variant the app knows how to download
//  and run. Each snapshot is a (family, capability, precision) triple — a
//  point in the matrix exposed by mlx-community/qwen3-tts.
//
//  The full matrix (18 valid combinations on mlx-community as of 2026-04):
//
//                    4bit  5bit  6bit  8bit  bf16
//    0.6B Base        ✓     ✓     ✓     ✓     ✓
//    0.6B CustomVoice ✓     ✓     ✓     ✓     ✓
//    1.7B Base        —     —     —     —     ✓
//    1.7B CustomVoice —     —     —     ✓     ✓
//    1.7B VoiceDesign ✓     ✓     ✓     ✓     ✓
//
//  Empty cells aren't published by mlx-community — they simply don't exist.
//

import Foundation
#if os(iOS)
import UIKit
#endif

// MARK: - Axes

/// Parameter count. The 1.7B family produces noticeably better prosody and
/// emotion control; the 0.6B family is faster and uses about half the disk.
enum ModelFamily: String, CaseIterable, Hashable, Sendable, Codable {
    case b06 = "0.6B"
    case b17 = "1.7B"

    var displayName: String { rawValue }

    /// Where to fetch the matching `tokenizer.json` from — mlx-community
    /// snapshots ship without it, so we pull from the upstream Qwen3 LLM
    /// (same vocab and merges). Same family ⇒ same tokenizer.
    var tokenizerJsonURL: String {
        switch self {
        case .b06: return "https://huggingface.co/Qwen/Qwen3-0.6B/resolve/main/tokenizer.json"
        case .b17: return "https://huggingface.co/Qwen/Qwen3-1.7B/resolve/main/tokenizer.json"
        }
    }
}

/// Which Qwen3-TTS *capability head* this snapshot is. Distinct from
/// `TTSCapability` (the user-facing intent): a `Base` snapshot can satisfy
/// both the voice-clone and preset capabilities, for example.
enum SnapshotCapability: String, CaseIterable, Hashable, Sendable, Codable {
    /// Voice cloning + the same preset speakers CustomVoice exposes. Ships
    /// the SeanetEncoder weights CustomVoice does not.
    case base
    /// Preset speakers (Vivian/Ryan/etc.) with optional emotion/style overlay.
    case customVoice
    /// Brand-new voice from a free-form description, no preset speaker.
    /// Only released at 1.7B.
    case voiceDesign

    var displayName: String {
        switch self {
        case .base:        return "Voice Cloning"
        case .customVoice: return "Preset Voices"
        case .voiceDesign: return "Voice Design"
        }
    }

    /// Which user-facing TTS capabilities this snapshot can satisfy. `Base`
    /// is a superset that also runs the preset path.
    var ttsCapabilities: Set<TTSCapability> {
        switch self {
        case .base:        return [.voiceClone, .customVoice]
        case .customVoice: return [.customVoice]
        case .voiceDesign: return [.voiceDesign]
        }
    }

    /// One-line description used in the Model Manager and the missing-model
    /// prompt. Power-user audience — assumes they know what cloning is.
    var summary: String {
        switch self {
        case .base:
            return "Clone any voice from a short reference clip. Also runs the preset speakers."
        case .customVoice:
            return "Built-in speakers with optional emotion / style instruction."
        case .voiceDesign:
            return "Generate a brand-new voice from a free-form description. 1.7B only."
        }
    }
}

/// Quantization tier. `bf16` is the reference (full mlx-converted) precision;
/// the integer tiers trade quality for disk and RAM. TTS is more sensitive to
/// quantization than text LLMs — auditory artifacts may be audible below 6bit.
enum ModelPrecision: String, CaseIterable, Hashable, Sendable, Codable {
    case q4 = "4bit"
    case q5 = "5bit"
    case q6 = "6bit"
    case q8 = "8bit"
    case bf16 = "bf16"

    var displayName: String {
        switch self {
        case .q4:   return "4-bit"
        case .q5:   return "5-bit"
        case .q6:   return "6-bit"
        case .q8:   return "8-bit"
        case .bf16: return "bf16 (full)"
        }
    }

    /// Power-user hint shown next to the precision in the manager. Honest
    /// trade-offs, no marketing copy.
    var qualityHint: String {
        switch self {
        case .q4:   return "Smallest, fastest. May audibly degrade prosody — sample before relying on it."
        case .q5:   return "Slightly larger than 4-bit; usually a clear quality bump."
        case .q6:   return "Sweet spot for many users — close to bf16 in listening tests."
        case .q8:   return "Near-lossless vs bf16 at half the disk."
        case .bf16: return "Reference precision. Use this when quality matters more than disk."
        }
    }

    /// The best default precision for the current platform and device RAM.
    /// macOS can comfortably run bf16. On iOS jetsam limits vary by device:
    ///   iPad Pro M-series (≥ 8 GB): bf16
    ///   ≥ 6 GB RAM (iPhone 14 Pro, iPhone 15, iPhone 16): q8
    ///   < 6 GB RAM (older iPhones, 4 GB devices): q4
    static var platformDefault: ModelPrecision {
        #if os(iOS)
        let physicalBytes = ProcessInfo.processInfo.physicalMemory
        let physicalGB = Double(physicalBytes) / 1_073_741_824  // bytes → GiB
        // iPad Pro M-series ships with ≥ 8 GB unified memory and a much higher
        // jetsam ceiling than iPhone — bf16 fits comfortably there.
        let isHighMemoryiPad = UIDevice.current.userInterfaceIdiom == .pad && physicalGB >= 8
        if isHighMemoryiPad { return .bf16 }
        return physicalGB >= 6 ? .q8 : .q4
        #else
        return .bf16
        #endif
    }

    /// Higher = better quality. Used only for sorting in the UI.
    var qualityRank: Int {
        switch self {
        case .q4:   return 0
        case .q5:   return 1
        case .q6:   return 2
        case .q8:   return 3
        case .bf16: return 4
        }
    }

    /// True when the safetensors file is sharded (and therefore needs a
    /// `model.safetensors.index.json`). Empirically only `bf16` shards.
    var isSharded: Bool { self == .bf16 }
}

// MARK: - Snapshot

/// One downloadable Qwen3-TTS variant — a (family, capability, precision)
/// triple. The on-disk directory name is `directoryName` (also serves as the
/// stable id for persistence and Identifiable).
struct ModelSnapshot: Hashable, Identifiable, Sendable, Codable {

    let family: ModelFamily
    let capability: SnapshotCapability
    let precision: ModelPrecision

    var id: String { directoryName }

    // MARK: - Static registry

    /// Every (family, capability, precision) combination mlx-community
    /// actually publishes. Adding a new published variant is a one-line edit
    /// here — everything else (manifest, UI rows, download flow) is derived.
    static let allCases: [ModelSnapshot] = {
        var snaps: [ModelSnapshot] = []
        // 0.6B — Base & CustomVoice exist at every precision.
        for cap in [SnapshotCapability.base, .customVoice] {
            for p in [ModelPrecision.q4, .q5, .q6, .q8, .bf16] {
                snaps.append(ModelSnapshot(family: .b06, capability: cap, precision: p))
            }
        }
        // 1.7B Base — bf16 only.
        snaps.append(ModelSnapshot(family: .b17, capability: .base, precision: .bf16))
        // 1.7B CustomVoice — 8bit and bf16.
        snaps.append(ModelSnapshot(family: .b17, capability: .customVoice, precision: .q8))
        snaps.append(ModelSnapshot(family: .b17, capability: .customVoice, precision: .bf16))
        // 1.7B VoiceDesign — every precision.
        for p in [ModelPrecision.q4, .q5, .q6, .q8, .bf16] {
            snaps.append(ModelSnapshot(family: .b17, capability: .voiceDesign, precision: p))
        }
        return snaps
    }()

    /// Look up a snapshot by its on-disk directory name. Used to deserialize
    /// the user's per-capability selection from `UserDefaults`.
    static func find(directoryName name: String) -> ModelSnapshot? {
        allCases.first { $0.directoryName == name }
    }

    // MARK: - Identity strings

    /// Stable on-disk directory name. Embeds all three axes so multiple
    /// variants coexist without collision.
    var directoryName: String {
        "Qwen3TTS-\(family.rawValue)-\(capabilityToken)-\(precision.rawValue)"
    }

    /// The HF repo that hosts this snapshot's weights & configs.
    var hfRepo: String {
        "mlx-community/Qwen3-TTS-12Hz-\(family.rawValue)-\(capabilityToken)-\(precision.rawValue)"
    }

    /// Capability token used in HF repo / directory names. Matches
    /// upstream casing: "Base", "CustomVoice", "VoiceDesign".
    private var capabilityToken: String {
        switch capability {
        case .base:        return "Base"
        case .customVoice: return "CustomVoice"
        case .voiceDesign: return "VoiceDesign"
        }
    }

    // MARK: - User-facing metadata

    /// Short label like "Voice Cloning · 0.6B · 8-bit". Used everywhere a
    /// snapshot needs a one-line name (manager rows, missing-model prompt,
    /// settings storage row).
    var displayName: String {
        "\(capability.displayName) · \(family.displayName) · \(precision.displayName)"
    }

    /// Two-line summary: capability blurb + precision trade-off. Shown in
    /// the manager.
    var summary: String {
        "\(capability.summary) — \(precision.qualityHint)"
    }

    /// Which TTS capabilities this specific snapshot can satisfy. Mirrors
    /// `capability.ttsCapabilities`.
    var capabilities: Set<TTSCapability> { capability.ttsCapabilities }

    /// Approximate total bytes for progress UI; doesn't have to be exact.
    var approxBytes: Int64 {
        manifest.reduce(0) { $0 + $1.expectedBytes }
    }

    // MARK: - Manifest

    /// Estimated `model.safetensors` size. Empirical for the bf16 entries we
    /// actually ship, scaled for the integer precisions. Used only for the
    /// progress UI and disk-space precheck — actual server bytes win.
    private var modelWeightBytes: Int64 {
        switch (family, precision) {
        case (.b06, .bf16): return 1_811_626_550
        case (.b06, .q8):   return 950_000_000
        case (.b06, .q6):   return 750_000_000
        case (.b06, .q5):   return 620_000_000
        case (.b06, .q4):   return 500_000_000
        case (.b17, .bf16): return 3_833_402_589
        case (.b17, .q8):   return 1_950_000_000
        case (.b17, .q6):   return 1_500_000_000
        case (.b17, .q5):   return 1_220_000_000
        case (.b17, .q4):   return 1_000_000_000
        }
    }

    var manifest: [ModelFile] {
        let base = "https://huggingface.co/\(hfRepo)/resolve/main"
        var files: [ModelFile] = [
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
            ModelFile(relativePath: "tokenizer_config.json",
                      downloadURL: "\(base)/tokenizer_config.json",
                      expectedBytes: 7_344),
            ModelFile(relativePath: "tokenizer.json",
                      downloadURL: family.tokenizerJsonURL,
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
        // Sharded only at bf16 — quantized variants ship a single safetensors
        // file with no index.
        if precision.isSharded {
            files.append(
                ModelFile(relativePath: "model.safetensors.index.json",
                          downloadURL: "\(base)/model.safetensors.index.json",
                          expectedBytes: 32_289)
            )
        }
        return files
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
