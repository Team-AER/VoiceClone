//
//  Sendability.swift
//  PolyJuiceVoice
//
//  `Qwen3TTSModel` inherits from `MLXNN.Module` which is not declared
//  Sendable. We need to call `model.generate(...)` from a `Task.detached`
//  to keep it off the MainActor (otherwise long syntheses freeze the UI),
//  which under Swift 6 strict concurrency requires Sendable conformance.
//
//  This is `@unchecked Sendable` because we manually serialise generation
//  via `MLXTTSService`'s state machine: `.synthesizing` blocks any second
//  capability load or synthesize call, so the model is never accessed
//  concurrently. Internally MLX dispatches GPU work through its own thread-
//  safe Metal command queue.
//

extension Qwen3TTSModel: @unchecked Sendable {}
