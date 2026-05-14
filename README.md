# Dictly

> Press a hotkey. Speak. Paste anywhere.

A free, open-source macOS menu-bar dictation app. Hold a global hotkey, speak,
release — your speech is transcribed locally by Whisper and placed on the
clipboard (or auto-pasted into the focused app, depending on build).

**Apple Silicon only · macOS 15+ · 99 languages · 100% on-device**

No cloud API. No account. No telemetry. Audio never leaves your Mac.

## Highlights

- **Global push-to-talk hotkey** (default `⌥Space` on the App Store build, `Fn`
  on the Direct build). Configurable in Settings.
- **OpenAI Whisper via [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)**,
  running on Apple's CoreML / Neural Engine. Real-time-factor ≈ 0.1–0.3 on M-series.
- **99 languages** supported by Whisper out of the box. Auto-detection or pinned
  language in Settings.
- **Bundled model** (Whisper `base` multilingual, ~139 MB) — ships in-repo so
  the app works offline from first launch. Higher-quality variants (large-v3,
  large-v3-turbo, etc.) are downloadable from HuggingFace inside the app, or
  fetchable up front via `scripts/fetch_bundled_model.py <variant>`.
- **Pure AppKit**, no SwiftUI dependencies.
- **Two distribution paths**:
  - **Direct** (default) — full functionality, auto-pastes via simulated ⌘V
    (needs Accessibility permission).
  - **App Store** (`#if APP_STORE`) — clipboard-only, sandboxed, no Accessibility
    request. Same source, different build configuration.

## Project layout

```
Dictly/
├── Dictly.xcodeproj/
├── Dictly/                        main app target sources
│   ├── App/                     AppDelegate, DictationCoordinator
│   ├── MenuBar/                 NSStatusItem + menu
│   ├── Hotkey/                  KeyCombo, HotkeyManager (Carbon RegisterEventHotKey)
│   ├── Audio/                   AudioRecorder (AVAudioEngine → 16 kHz mono Float32)
│   ├── Transcription/           Transcriber protocol, WhisperKit, ModelCatalog
│   ├── TextInsertion/           TextInserter (clipboard + simulated ⌘V)
│   ├── PostProcessing/          Hook for post-transcription cleanup
│   ├── Permissions/             Mic + Accessibility checks
│   ├── Settings/                UserDefaults wrapper, settings window
│   ├── HUD/                     Floating "pill" recording HUD
│   ├── Onboarding/              First-run window (permissions + model download)
│   ├── Design/                  DesignTokens, BrandButton, RingedIcon
│   ├── Dictly.entitlements           Direct distribution
│   └── PrivacyInfo.xcprivacy
└── BundledModels/               `base` model (~139 MB) ships in-repo;
                                   larger variants fetched on demand
scripts/
├── fetch_bundled_model.py       Downloads the bundled Whisper model
├── sync_icons.sh                Regenerates app/menu-bar icons from sources
└── sync_menubar_icons.swift
```

## Building from source

### Prerequisites

- macOS 15 (Sequoia) or newer
- Apple Silicon Mac
- Xcode 16+
- Python 3 (only needed if you want to bundle a different Whisper variant
  than the `base` model that ships in-repo)

### Steps

```bash
# 1. Open in Xcode
open Dictly/Dictly.xcodeproj

# 2. Set your own signing team:
#    • Project → target Dictly → Signing & Capabilities
#    • Team: pick your Apple Developer team
#    • Bundle Identifier: change `com.mydear.voicetotext` to something
#      registered to your team (e.g. `com.yourname.dictly`)

# 3. Build & run. The bundled `base` model is already in
#    Dictly/BundledModels/ — the app boots offline-ready.

# (optional) Bundle a heavier model alongside `base`. For example:
python3 scripts/fetch_bundled_model.py large-v3-v20240930_547MB
# After rebuilding, the app picks the highest-quality bundled model as
# its default (see `ModelInfo.defaultModelID`); switching is live in
# Settings → Transcription models.
```

> **Note:** This repository ships the **Direct distribution** build only
> (full functionality, auto-pastes via simulated ⌘V, needs Accessibility).
> The Mac App Store variant (sandboxed, clipboard-only) is maintained
> privately by the original author.

Or from the command line:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Dictly/Dictly.xcodeproj \
             -scheme Dictly -configuration Release build

open "$(find ~/Library/Developer/Xcode/DerivedData -name Dictly.app -type d | head -1)"
```

## How it works (one-paragraph version)

`DictationCoordinator` owns the long-lived components. On hotkey press,
`AudioRecorder` boots a fresh `AVAudioEngine` and starts streaming 16 kHz mono
Float32 PCM into a buffer. On release, the buffer is handed to
`WhisperKitTranscriber`, which calls Whisper on the bundled CoreML model. The
resulting text passes through a `TextPostProcessor` and is then either pasted
into the focused app (Direct build, via `CGEvent` simulating ⌘V) or copied to
the clipboard for the user to paste manually (App Store build). A floating HUD
shows recording/transcribing/done states throughout.

## Configuration

Settings live in `UserDefaults` (or the App Sandbox container for the App Store
build). Key options:

| Setting | Default | Notes |
| --- | --- | --- |
| Hotkey | `Fn` (Direct) / `⌥Space` (App Store) | Reassignable |
| Mode | Push-to-talk | or toggle |
| Spoken language | `auto` | ISO 639-1 or `auto` |
| Quality | Balanced | Fast / Balanced / Best — maps to Whisper's `temperatureFallbackCount` |
| Auto-paste | On (Direct) / N/A (App Store) | Requires Accessibility on Direct |
| HUD position | Bottom of screen | or under menu bar icon |

## Logging

All logs use `os.Logger` with subsystem `com.mydear.voicetotext`:

```bash
log stream --predicate 'subsystem == "com.mydear.voicetotext"' --info
```

A pipeline timing line lands at `.notice` level after each dictation:

```
⏱️ pipeline: total=1.08s (transcribe=1.05s · post=0.00s · insert=0.03s) for 3.07s audio
```

## License

See [LICENSE](LICENSE).

## Contributing

Issues and PRs welcome. Please open an issue before large changes so we can
discuss the approach.
