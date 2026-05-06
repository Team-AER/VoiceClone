# Privacy Policy

**App:** PolyJuiceVoice  
**Developer:** AER  
**Contact:** prafiles@gmail.com  
**Effective Date:** May 6, 2026

---

## Summary

PolyJuiceVoice processes everything **on your device**. We do not collect, transmit, or sell any personal data. The only ways data leaves your device are (1) downloading the AI model weights on first launch, and (2) optional iCloud sync between your own devices, which is off by default and described below.

---

## What We Collect

### Microphone Audio
When you use the Voice Cloning feature, the app records short voice samples through your microphone — for example, you reading a passage of text aloud — so that the synthesizer can create a voice that matches the timbre and style of your recording. This audio is:
- Processed entirely on-device using Apple's Metal framework
- Held in a temporary recording buffer during capture and only saved to your Voice Library when you explicitly choose to save the cloned voice
- Never uploaded to any server operated by us, and never shared with any third party
- If — and only if — you turn on iCloud Sync in Settings, included in the items that sync between your own devices via your private iCloud container (see the iCloud Sync section below)

### Speech Recognition
When you record a reference clip, the app transcribes it on-device using Apple's Speech framework so the synthesizer knows which words match the audio. The resulting transcript:
- Is generated on-device — the audio is not sent to Apple or any third party for transcription
- Is paired with the recording and stored alongside the cloned voice in your local Voice Library
- Is deleted when you delete the corresponding voice

### Voice Library Data
Voices you create or clone are saved locally using Core Data on your device. This data:
- Remains on your device by default
- Can be deleted at any time from within the app
- Is synced between your own devices via your private iCloud container only if you turn on iCloud Sync in Settings (see the iCloud Sync section below)

### iCloud Sync (Optional, Off by Default)
PolyJuiceVoice can optionally sync your Voice Library across the devices signed in to your Apple ID. This feature:
- Is **off by default** — you must explicitly enable it in Settings, and a restart is required for the change to take effect
- Uses your own **private iCloud container** (`iCloud.app.aer.PolyJuiceVoice`) via Apple's CloudKit and iCloud Documents — your data is stored under your Apple ID, not on any server we operate, and we have no access to it
- Syncs voice profile metadata (name, language, instruction text, creation date) along with the associated reference audio recordings and voice embedding files
- Sync is governed by Apple's [iCloud Privacy](https://www.apple.com/legal/privacy/data/en/icloud/) policies once data is in your iCloud account
- Can be disabled at any time in Settings; turning it off stops further syncing and the data already on your other devices remains under your control via Apple's iCloud management tools

### Model Downloads
On first launch, the app downloads approximately 4 GB of AI model weights from Hugging Face (`huggingface.co`) to your device. After the initial download:
- The models are cached locally
- No further network requests are made during normal use
- No personal data is sent during the download

---

## What We Do Not Collect

- No account or registration is required
- No analytics or usage data is collected
- No crash reports are transmitted
- No advertising identifiers are used
- No data is sold or shared with third parties

---

## Data Storage

All app data (voice recordings, synthesized audio, voice profiles) is stored locally on your device in:
- **macOS:** `~/Library/Application Support/PolyJuiceVoice/`
- **iOS:** The app's sandboxed Documents directory

If you have enabled iCloud Sync, the same data is also stored in your private iCloud container under your Apple ID and replicated across your devices.

You can delete all app data by uninstalling the app. If iCloud Sync was enabled, you can additionally manage or delete the data stored in your iCloud account via System Settings → Apple ID → iCloud → Manage Account Storage on Apple's platforms.

---

## Permissions

| Permission | Purpose |
|---|---|
| Microphone | Record short reference clips (e.g. you reading a passage aloud) so the app can clone your voice. Recordings stay on-device and are only saved to your Voice Library when you choose to save the voice. |
| Speech Recognition | Transcribe your reference recording on-device so the synthesizer can pair the spoken words with the audio. |
| Network (outgoing) | Download AI model weights on first launch; iCloud Sync traffic if you enable it |
| File Access (user-selected) | Export synthesized audio to locations you choose via the system save dialog |
| iCloud (CloudKit + iCloud Documents) | Optional sync of your Voice Library between your own devices via your private iCloud container. Off by default. |

---

## Children's Privacy

PolyJuiceVoice does not knowingly collect any information from children under 13. The app requires no account and transmits no personal data.

---

## Changes to This Policy

If we update this policy, we will revise the Effective Date above. Continued use of the app after changes constitutes acceptance of the updated policy.

---

## Contact

Questions about this privacy policy? Email us at **prafiles@gmail.com**.
