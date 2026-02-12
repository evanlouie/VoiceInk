# VoiceInk — AI Agent Guidelines

## Architecture

VoiceInk is a macOS speech-to-text app built with **Swift (hybrid SwiftUI + AppKit)**. It wraps [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for local transcription and connects to cloud providers (Groq, Deepgram, ElevenLabs, Gemini, Mistral, Soniox, OpenAI-compatible).

**Core pipeline:** Record audio → Transcribe (local or cloud) → Optional word replacement → Optional AI enhancement → Paste at cursor via simulated ⌘V.

Key subsystems:

- **`WhisperState`** ([VoiceInk/Whisper/](../VoiceInk/Whisper/)) — central orchestrator for recording, transcription, and enhancement. Split across extensions (`+LocalModelManager`, `+ModelManagement`, `+Parakeet`, `+UI`, etc.).
- **`CoreAudioRecorder`** ([VoiceInk/CoreAudioRecorder.swift](../VoiceInk/CoreAudioRecorder.swift)) — low-level AUHAL recording. Converts all input to 16kHz mono 16-bit PCM (whisper.cpp format). Supports mid-recording device switching.
- **Services/** ([VoiceInk/Services/](../VoiceInk/Services/)) — transcription providers (`CloudTranscription/`, `StreamingTranscription/`), AI enhancement (`AIEnhancement/`), audio device management, licensing, etc.
- **PowerMode/** ([VoiceInk/PowerMode/](../VoiceInk/PowerMode/)) — context-aware profiles that auto-select model/prompt/language based on active app or browser URL. Uses AppleScript (`.scpt` files in `Resources/`) for browser URL detection.
- **Views/** ([VoiceInk/Views/](../VoiceInk/Views/)) — SwiftUI views organized by feature subdirectory.
- **Data layer:** SwiftData with two stores — `default.store` (transcriptions) and `dictionary.store` (vocabulary/word replacements). CloudKit sync on `dictionary.store` (disabled via `#if LOCAL_BUILD`).

## Code Style

- `@MainActor` on most classes; `WhisperContext` uses Swift actor isolation
- Singletons via `static let shared` for global services (`WindowManager`, `PowerModeManager`, `AudioDeviceManager`)
- `@Published` + `ObservableObject` for reactive state (minimal Combine pipelines)
- `NotificationCenter` for cross-component events (see [AppNotifications.swift](../VoiceInk/Notifications/AppNotifications.swift))
- `MARK:` comments to organize file sections
- Logger subsystem: `"com.prakashjoshipax.voiceink"`
- API keys stored in macOS Keychain via `KeychainService` / `APIKeyManager` — never store keys in UserDefaults or plain files

## Build and Test

**Never use `swift build`** — [Package.swift](../Package.swift) exists solely for SourceKit-LSP support.

```sh
make whisper   # Clone & build whisper.cpp xcframework (required first time)
make build     # Debug build via xcodebuild (requires Apple Developer signing)
make local     # Ad-hoc signed build without developer cert → ~/Downloads/VoiceInk.app
make dev       # Build + run
make clean     # Remove ~/VoiceInk-Dependencies/
```

`make local` uses [LocalBuild.xcconfig](../LocalBuild.xcconfig) with ad-hoc signing and stripped entitlements. The `LOCAL_BUILD` Swift flag enables `#if LOCAL_BUILD` conditional compilation (disables CloudKit sync).

Tests are minimal (boilerplate only in `VoiceInkTests/` and `VoiceInkUITests/`).

## Project Conventions

- **Dependency injection** in `VoiceInkApp.init()` ([VoiceInk.swift](../VoiceInk/VoiceInk.swift)), passed through `@EnvironmentObject` in views
- **Transcription models** conform to the `TranscriptionModel` protocol with concrete types: `LocalModel`, `CloudModel`, `CustomCloudModel`, `ParakeetModel`, `NativeAppleModel` (see [TranscriptionModel.swift](../VoiceInk/Models/TranscriptionModel.swift))
- **Cloud transcription services** implement `TranscriptionService` protocol; streaming ones implement `StreamingTranscriptionService`
- **Two recording modes:** push-to-talk (hold modifier key) and hands-free (tap to toggle). Configured via `HotkeyManager`.
- **App sandbox is disabled** by design — required for CGEvent posting (paste-at-cursor), global NSEvent monitoring (hotkeys), AppleScript automation, and Accessibility API access
- **Bundle ID:** `com.prakashjoshipax.VoiceInk` — used for UserDefaults suites, iCloud containers, and logger subsystem

## Security

- API keys → macOS Keychain only (see `KeychainService`, `APIKeyManager`)
- Sandbox disabled: be careful not to introduce file system operations outside expected paths (`~/Library/Application Support/com.prakashjoshipax.VoiceInk/`)
- The app executes AppleScripts and posts CGEvents — validate inputs to these operations
- Network calls go to third-party AI APIs — handle auth tokens securely, never log them

## Pull Requests

Per [CONTRIBUTING.md](../CONTRIBUTING.md), external pull requests are **not accepted**. Contributions are limited to bug reports, feature suggestions, and forks.
