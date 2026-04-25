# Qwen3TTS — vendored source

The Swift files in this directory are vendored verbatim from an upstream open-source project.
They are compiled as part of the PolyJuiceVoice target, not pulled via Swift Package Manager.

## Upstream

- **Repository**: https://github.com/AtomGradient/swift-qwen3-tts
- **Commit**: `27a5b5b2c5d55258bead2c6e851208987e1ca225`
- **Date fetched**: 2026-04-25
- **License**: MIT (per upstream README; no LICENSE file in the repository at this commit)

The upstream project is itself a Swift port of
[Blaizzy/mlx-audio](https://github.com/Blaizzy/mlx-audio)'s Python MLX
implementation of Qwen3-TTS.

## Why vendored

Pinning an external Swift Package Manager dependency to a small personal repo was
judged lower-trust than committing a known-good snapshot into our own source tree,
where every line is visible in our git history. If the upstream ever disappears,
moves, or changes, nothing here is affected.

## Modifications

None at the time of vendoring — files copied as-is. Any local changes will be
tracked in the regular git history of this repository.
