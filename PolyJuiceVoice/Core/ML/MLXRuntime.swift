//
//  MLXRuntime.swift
//  PolyJuiceVoice
//
//  One-shot MLX bootstrap: pin the default device to GPU, set sane Metal
//  memory + cache + wired limits, and emit a one-line boot log so we can
//  verify at runtime that inference is hitting the GPU (not silently
//  running on CPU).
//
//  Background:
//    - mlx-swift defaults to .gpu when no default is set (Device.swift line
//      105: `_defaultDevice ?? .gpu`), but we set it explicitly anyway so
//      the intent is unambiguous and any future regression is easy to spot.
//    - The default cache limit equals the memory limit, which on a 64 GB
//      Apple Silicon Mac defaults to ~1.5× the recommended working set
//      (~48 GB). That can balloon RSS when running long generations and
//      cause the OS to page out the model. A 512 MB cache performs as well
//      in practice (per mlx-swift docs) and keeps RSS predictable.
//    - Wiring memory keeps the model resident in unified memory so it's
//      never paged to swap during a multi-second autoregressive generation.
//

import Foundation
import MLX

enum MLXRuntime {

    /// Run once at app launch. Idempotent — safe to call again.
    /// Returns a snapshot describing the configuration so the caller can
    /// log it (or surface it in a debug overlay later).
    @discardableResult
    static func bootstrap() -> Configuration {
        // 0. Guard rails. MLX requires Metal — the iOS Simulator can't run
        //    this app at all. Fail loudly with a useful message instead of
        //    a cryptic Metal-not-available error deep inside generation.
        #if targetEnvironment(simulator)
        AppLog.fault(
            "PolyJuiceVoice cannot run in the iOS Simulator — MLX requires Metal hardware. " +
            "Build for 'My Mac (Designed for iPad)' or a physical device.",
            "runtime"
        )
        #endif

        // 0.1. Sweep stale recordings / exports the previous session left behind.
        TempCleaner.sweep()

        // 1. Pin the default device to .gpu explicitly.
        Device.setDefault(device: .gpu)

        // 2. Read what Metal reports for this machine.
        let info = GPU.deviceInfo()
        let recommendedSet = Int(info.maxRecommendedWorkingSetSize)

        // 3. Memory limit: the mlx-swift default is 1.5× recommended. We
        //    cap at exactly the recommended working set to avoid spilling
        //    into swap — model + activations for the 1.7B bf16 snapshot
        //    plus the speech tokenizer top out around ~5 GB, well under
        //    the recommended set on any Apple Silicon Mac that can run
        //    this app.
        let memoryLimit = max(recommendedSet, 4 * 1024 * 1024 * 1024)
        GPU.set(memoryLimit: memoryLimit, relaxed: true)

        // 4. Cache limit: 512 MB. The MLX docs explicitly call out that
        //    small cache sizes (~tens of MB) often perform as well as
        //    unbounded for inference; we leave headroom for the speech
        //    tokenizer's intermediate buffers without growing RSS by
        //    several GB across many generations.
        let cacheLimit = 512 * 1024 * 1024
        GPU.set(cacheLimit: cacheLimit)

        let config = Configuration(
            device: Device.defaultDevice(),
            architecture: info.architecture,
            maxBufferBytes: info.maxBufferSize,
            recommendedWorkingSetBytes: recommendedSet,
            systemMemoryBytes: info.memorySize,
            memoryLimitBytes: memoryLimit,
            cacheLimitBytes: cacheLimit
        )
        log(config)
        return config
    }

    struct Configuration {
        let device: Device
        let architecture: String
        let maxBufferBytes: Int
        let recommendedWorkingSetBytes: Int
        let systemMemoryBytes: Int
        let memoryLimitBytes: Int
        let cacheLimitBytes: Int

        var isGPU: Bool { device.deviceType == .gpu }
    }

    // MARK: - Logging

    private static func log(_ config: Configuration) {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .memory
        let memLimit = fmt.string(fromByteCount: Int64(config.memoryLimitBytes))
        let cacheLimit = fmt.string(fromByteCount: Int64(config.cacheLimitBytes))
        let recommended = fmt.string(fromByteCount: Int64(config.recommendedWorkingSetBytes))
        let sysMem = fmt.string(fromByteCount: Int64(config.systemMemoryBytes))
        let deviceLabel = config.isGPU ? "Metal GPU" : "CPU (FALLBACK)"
        AppLog.notice(
            "MLX runtime ready — device: \(deviceLabel) (\(config.architecture)), " +
            "sys mem: \(sysMem), recommended working set: \(recommended), " +
            "mem limit: \(memLimit), cache limit: \(cacheLimit)",
            "runtime"
        )
        if !config.isGPU {
            AppLog.warning("MLX fell back to CPU — inference will be slow.", "runtime")
        }
    }
}
