//
//  TextSanitizer.swift
//  PolyJuiceVoice
//
//  Lightweight pre-flight check for synthesis input. Each view model runs
//  the user's text through `TextSanitizer.sanitize(_:)` before handing it
//  to MLXTTSService — so we never feed the model an empty, control-char-
//  laden, or absurdly long string and end up with garbled audio or an OOM.
//

import Foundation

enum TextSanitizerResult {
    case valid(text: String)
    case warning(text: String, reason: String)
    case rejected(reason: String)

    /// Convenience for "ready to synthesize?": both `.valid` and `.warning`
    /// pass; `.rejected` blocks.
    var passes: Bool {
        switch self {
        case .valid, .warning: return true
        case .rejected:        return false
        }
    }

    /// The cleaned-up text safe to pass to the model. Nil only when rejected.
    var sanitized: String? {
        switch self {
        case .valid(let t):       return t
        case .warning(let t, _):  return t
        case .rejected:           return nil
        }
    }

    /// Human-readable reason for `.warning` / `.rejected`. Nil for `.valid`.
    var message: String? {
        switch self {
        case .valid:                return nil
        case .warning(_, let r):    return r
        case .rejected(let r):      return r
        }
    }
}

enum TextSanitizer {

    /// Soft warning above this threshold; synthesis still allowed but UI
    /// can show "this will take a while" copy.
    static let warningCharacterCount = 1500
    /// Hard cap. Above this we refuse to synthesize because RAM + time would
    /// be unreasonable.
    static let maxCharacterCount = 8000

    static func sanitize(_ raw: String) -> TextSanitizerResult {
        // 1. Strip control characters except newline + tab.
        let allowedControl: Set<Character> = ["\n", "\t"]
        let stripped = String(raw.filter { ch in
            !ch.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && !allowedControl.contains(ch) }
        })

        // 2. Collapse runs of whitespace.
        let collapsed = stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return .rejected(reason: "Type some text to synthesize.")
        }

        if trimmed.count < 2 {
            return .rejected(reason: "Text is too short — add at least a couple of characters.")
        }

        if trimmed.count > maxCharacterCount {
            return .rejected(reason: "Text is too long (\(trimmed.count) characters). Maximum is \(maxCharacterCount).")
        }

        if trimmed.count > warningCharacterCount {
            return .warning(
                text: trimmed,
                reason: "That's a long passage (\(trimmed.count) characters). Synthesis may take a minute."
            )
        }

        return .valid(text: trimmed)
    }
}
