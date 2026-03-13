# Qwen3-ASR Integration — Handoff

## Status: Code Complete & Building, Needs Runtime Verification

All code is committed to `main` (commit `34365e3`), `make local` passes with `BUILD SUCCEEDED`. The integration has **not been runtime-tested** — the speech-swift API was inferred from reading GitHub source, not from running the app.

## What Was Done

All 11 steps from the original plan were implemented, following the existing Parakeet integration pattern exactly.

### New Files (3)
| File | Purpose |
|------|---------|
| `VoiceS/Whisper/QwenModelManager.swift` | Model download/delete manager. Uses `Qwen3ASRModel.fromPretrained(modelId:progressHandler:)` for download, UserDefaults for state. |
| `VoiceS/Services/QwenTranscriptionService.swift` | Transcription service. Loads model via `fromPretrained`, calls `model.transcribe(audio:sampleRate:)`. Has its own `QwenTranscriptionError` enum. |
| `VoiceS/Views/AI Models/QwenModelCardRowView.swift` | SwiftUI card with download progress, set-as-default, delete, show-in-Finder. |

### Modified Files (9)
| File | Change |
|------|--------|
| `TranscriptionModel.swift` | Added `case qwen = "Qwen"` to `ModelProvider` enum. Added `QwenModel` struct with `modelId: String` field (HuggingFace repo ID). |
| `PredefinedModels.swift` | Added 30-language filter for `.qwen` provider. Added two model entries: `qwen3-asr-0.6b` (680MB, 4-bit) and `qwen3-asr-1.7b` (2.1GB, 8-bit). |
| `TranscriptionServiceRegistry.swift` | Added `qwenTranscriptionService` lazy property, `.qwen` case in `service(for:)`, cleanup call. |
| `TranscriptionModelManager.swift` | Added `qwenModelManager` init parameter (breaking change — all call sites updated). Wired deletion/change callbacks. Added `.qwen` case to `usableModels`. |
| `ModelCardRowView.swift` | Added `qwenModelManager: QwenModelManager` parameter. Added `.qwen` case dispatching to `QwenModelCardRowView`. |
| `ModelManagementView.swift` | Added `@EnvironmentObject private var qwenModelManager: QwenModelManager`. Added `.qwen` to local filter. Passes `qwenModelManager` to `ModelCardRowView`. |
| `VoiceS.swift` | Added `@StateObject private var qwenModelManager`. Creates `QwenModelManager()` in init. Passes to `TranscriptionModelManager`. Injects `.environmentObject(qwenModelManager)` into all 3 view hierarchies (ContentView, OnboardingView, MenuBarExtra). |
| `project.pbxproj` | Added `speech-swift` SPM package reference (`https://github.com/soniqo/speech-swift`, branch: main). Links only `Qwen3ASR` product to VoiceS target. |
| `Package.resolved` | Auto-updated by Xcode with all transitive deps (mlx-swift, swift-transformers, swift-jinja, etc.). |

## What Worked
- `make local` → `BUILD SUCCEEDED` → `~/Downloads/VoiceS.app`
- SPM dependency resolution for speech-swift and all transitive deps
- The Parakeet pattern was clean enough to replicate 1:1

## What Needs Runtime Verification

### 1. speech-swift API correctness
The API was inferred from GitHub source reading. Key calls to verify:

**QwenModelManager.swift (~line 52):**
```swift
_ = try await Qwen3ASRModel.fromPretrained(modelId: model.modelId) { progress, _ in
    // progress: Double, status: String
}
```

**QwenTranscriptionService.swift (~line 23 and ~33):**
```swift
let loaded = try await Qwen3ASRModel.fromPretrained(modelId: targetModelId)
let result: String = qwenModel.transcribe(audio: audioSamples, sampleRate: 16000)
```

If any of these signatures are wrong, fix only those two files.

### 2. HuggingFace model IDs
Verify these exist and are downloadable:
- `aufklarer/Qwen3-ASR-0.6B-MLX-4bit`
- `aufklarer/Qwen3-ASR-1.7B-MLX-8bit`

These are set in `PredefinedModels.swift` in the `modelId` field of each `QwenModel`.

### 3. Cache directory for delete/show-in-Finder
`QwenModelManager.qwenCacheDirectory()` assumes: `~/Library/Caches/qwen3-speech/{modelId_with_slash_replaced_by_underscore}/`

The speech-swift `HuggingFaceDownloader` has two strategies:
- Legacy flat: `~/Library/Caches/qwen3-speech/{sanitizedModelId}/`
- Hub-style: `~/Library/Caches/qwen3-speech/models/{org}/{model}/`

After downloading a model, check the actual path and update `qwenCacheDirectory()` if needed.

### 4. Model stats (speed/accuracy/RAM)
Values in `PredefinedModels.swift` are estimates:
- 0.6B: speed 0.95, accuracy 0.93, RAM 2.2GB
- 1.7B: speed 0.8, accuracy 0.96, RAM 4.5GB

Adjust after benchmarking.

### 5. Language codes
30 languages are in the Qwen filter. Qwen3-ASR actually supports 30 languages + 22 Chinese dialects. The filter may need expansion.

## How to Verify

```bash
cd /Users/gyudaekim/Projects/VoiceS
make local
open ~/Downloads/VoiceS.app
```

Then in the app:
1. Go to AI Models → Local tab
2. Qwen3-ASR 0.6B and 1.7B should appear
3. Click Download on 0.6B (smaller, faster test)
4. After download, set as default
5. Record audio and verify transcription works

## Architecture Quick Reference

Every Qwen file mirrors its Parakeet counterpart:

| Qwen | Parakeet (reference) |
|------|---------------------|
| `QwenModelManager.swift` | `ParakeetModelManager.swift` |
| `QwenTranscriptionService.swift` | `ParakeetTranscriptionService.swift` |
| `QwenModelCardRowView.swift` | `ParakeetModelCardRowView.swift` |

Key architectural difference: Parakeet uses separate `downloadAndLoad()` / `loadFromCache()` calls. Qwen uses a single `fromPretrained(modelId:)` that handles both downloading and caching internally.

## Build Prerequisites
These were installed during the session and should already be present:
- `cmake` (`brew install cmake`)
- Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`)
