# PolyJuiceVoice — App Store Connect metadata

Drop these straight into App Store Connect for the 1.0.0 submission.

---

## App Name (max 30 chars)

```
PolyJuiceVoice
```

## Subtitle (max 30 chars)

```
On-device voice synthesis
```

## Promotional Text (max 170 chars; can be updated without re-submission)

```
Take on any voice, design new ones from a description, or speak in a built-in style — entirely on-device. Your audio never leaves your Mac or iPhone.
```

## Description (max 4000 chars)

```
PolyJuiceVoice is on-device text-to-speech with three magical capabilities — built on Apple's MLX framework so every word is synthesized locally on your Mac or iPhone. Your text and recordings never leave the device.

— SPEAK —
Pick a built-in voice and read any text aloud, with optional style guidance like "calm and warm" or "energetic and confident." Long passages stream as they're generated, so you hear the first sentence in seconds.

— DESIGN —
Describe the voice you want — "a wise narrator with a slight British lilt" — and PolyJuiceVoice generates a brand-new speaker that matches. Save it to your library and re-use it for any future text.

— CLONE —
Record a few seconds of any voice (your own, with consent), then synthesize new sentences in that voice. Perfect for personal voice messages, accessibility, audiobook drafts, or character voices for storytelling.

— PRIVACY-FIRST BY DESIGN —
• 100% on-device synthesis. No cloud APIs, no audio uploads.
• No accounts, no analytics, no tracking.
• Models download once from Hugging Face on first launch (~4 GB) and stay local forever after.

— BUILT FOR APPLE SILICON —
PolyJuiceVoice uses Metal-accelerated inference via Apple's MLX framework for fast, energy-efficient synthesis. Designed for iOS 26 and macOS 26 with Liquid Glass throughout.

— FOR EVERYONE —
Built-in voices speak in English, Chinese, Japanese, Korean, Spanish, French, and German. Save unlimited voices to your personal library, export to WAV, and share generated audio anywhere.

PolyJuiceVoice is built on the open-source Qwen3-TTS model (Apache 2.0).

Requires Apple Silicon. iOS Simulator is not supported.
```

## Keywords (max 100 chars, comma-separated)

```
tts,voice,clone,ai,mlx,speech,narration,audiobook,podcast,accessibility,offline,private,on-device
```

## Support URL

```
https://github.com/prakharshukla/polyjuicevoice/issues
```

## Marketing URL (optional)

```
https://github.com/prakharshukla/polyjuicevoice
```

## Privacy Policy URL (required)

```
https://github.com/prakharshukla/polyjuicevoice/blob/main/PRIVACY.md
```

---

## What's New in This Version (max 4000 chars — for 1.0.0)

```
✨ The first public release of PolyJuiceVoice.

• Speak with built-in voices (Vivian, Ryan, and more) in 7 languages
• Design new voices from a free-text description
• Clone a voice from a short reference recording
• Save unlimited voices to your library
• 100% on-device synthesis — your audio never leaves your hardware
• Built for iOS 26 and macOS 26 with Liquid Glass throughout
• Optimized for Apple Silicon via Apple's MLX framework
```

---

## Privacy Nutrition Label (App Privacy section)

| Question | Answer |
|---|---|
| Does this app collect data? | **No** |
| Does this app use third-party SDKs that collect data? | **No** |
| Does this app track users across other apps and websites? | **No** |

Privacy categories: **None** — there is nothing to declare.

---

## Age Rating

| Question | Answer |
|---|---|
| Cartoon or Fantasy Violence | None |
| Realistic Violence | None |
| Sexual Content or Nudity | None |
| Profanity or Crude Humor | None |
| Mature/Suggestive Themes | None |
| Horror/Fear Themes | None |
| Medical/Treatment Information | None |
| Alcohol, Tobacco, or Drug Use or References | None |
| Simulated Gambling | None |
| Contests | None |
| Unrestricted Web Access | None |
| User Generated Content | None |

Resulting rating: **4+**.

⚠ **Disclosure to add in the description**: voice cloning carries an ethical
responsibility. Add the line "Use voice cloning only with the consent of the
person whose voice you record" prominently in onboarding before submission.

---

## Categories

- **Primary**: Productivity
- **Secondary**: Utilities

(Both are reasonable. Productivity ranks the app alongside other creator
tools; Utilities reflects that it's a building-block app rather than a
content app.)

---

## Localizations to add (post-launch)

The app's UI uses `LocalizedStringKey` literals throughout, so adding a
language is purely a translation exercise:

1. In Xcode: File → New → File → String Catalog. Already added at
   `PolyJuiceVoice/Resources/Localizable.xcstrings` (empty — Xcode auto-fills
   on next build).
2. After the next build, every UI string appears in the catalog.
3. Add target languages (Spanish, Mandarin, Japanese suggested first).
4. Send the catalog to a translator — they edit JSON-like rows.
5. Re-build, ship, no code changes.

---

## Screenshots

App Store Connect needs screenshots for both iOS and macOS at the standard
sizes. Take them with the app in **dark mode** (the Liquid Glass effect
shows best against a dark background) and showing:

| Screenshot | Tab/state |
|---|---|
| 1 | **Speak** — voice picker open, text typed, waveform visible mid-playback |
| 2 | **Clone** — recording in progress, level meter active |
| 3 | **Design** — voice description filled in, "Generate" CTA prominent |
| 4 | **Library** — list of saved voices |
| 5 | **Settings** — model storage row showing disk usage |

---

## Real-device test checklist (before submitting)

Run these on a physical iPhone (not the Simulator — MLX requires Metal):

- [ ] First-launch download: model gate appears, downloads complete with progress bar showing ETA
- [ ] Disk-space precheck: fill device to <5 GB free, verify download is refused with friendly error
- [ ] Mic permission grant + deny flow on Clone tab; "Open Settings" button works after deny
- [ ] Phone-call interruption mid-playback: audio pauses, resumes after call ends
- [ ] Headphones unplug mid-playback: audio pauses
- [ ] Background → foreground: re-enter app after 30s; UI and engine state intact
- [ ] Memory warning (iPhone 12 or older): model unloads gracefully, can re-load
- [ ] Voice library round-trip: save a cloned voice, force-quit, relaunch, verify it's there + plays correctly
- [ ] Long text (>1500 chars): warning surfaces, synthesis still completes
- [ ] Empty / whitespace-only / >8000 chars: rejected with friendly errors
- [ ] Dark mode + Liquid Glass renders cleanly on every tab
- [ ] VoiceOver: navigate every tab via swipe; all icon-only buttons have labels
