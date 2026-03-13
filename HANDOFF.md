# VoiceS Queue Recording + Processing Overlay Handoff

## Goal

Continue and finish the recent queue-based recording work, with special focus on the UI regression the user reported:

- before the queue refactor, a small recorder-style `"Transcribing"` / `"Enhancing"` UI appeared during processing
- after the refactor, that UI disappeared
- the user wants both of these to be true:
  - if there is only background transcription, the old processing UI should still appear
  - if recording B is active while recording A is still transcribing, the recording UI and the processing UI should both be visible at the same time

This handoff is intended to be enough for the next agent to start from this file alone.

## Current Status

What is implemented locally:

- queue-based recording is implemented
- recordings can be started again while previous transcription jobs are still processing
- queued jobs are processed serially in FIFO order
- queue limit is `10`
- enqueue-time settings snapshots are implemented for transcription/enhancement behavior
- recorder hotkey gating was relaxed to allow new recordings during background processing
- the missing processing UI was partially restored as a separate overlay window
- local packaging succeeds again and a build was produced at `~/Downloads/VoiceS.app`

What is still not finished:

- runtime verification in the actual app
- visual/positioning validation of the new processing overlay for both `mini` and `notch`
- confirmation that recording and processing UI coexist correctly in real hotkey flows
- confirmation that background-only processing still looks and behaves like the old UX
- stabilization of `xcodebuild test`

## Files Changed

Queue / engine changes:

- `VoiceS/Whisper/VoiceSEngine.swift`
- `VoiceS/Whisper/QueuedTranscriptionJob.swift`
- `VoiceS/Whisper/TranscriptionPipeline.swift`
- `VoiceS/Whisper/RecorderUIManager.swift`
- `VoiceS/HotkeyManager.swift`

Snapshot / enhancement support:

- `VoiceS/Services/AIEnhancement/AIEnhancementService.swift`
- `VoiceS/Services/PromptDetectionService.swift`
- `VoiceS/Whisper/TranscriptionModelManager.swift`

Recorder UI / overlay support:

- `VoiceS/Views/Recorder/RecorderStateProvider.swift`
- `VoiceS/Views/Recorder/BackgroundProcessingOverlayWindowManager.swift`

Tests:

- `VoiceSTests/VoiceSTests.swift`

## Architecture / What Changed

### 1. Foreground recording and background processing are now split

`VoiceSEngine` no longer uses a single linear state machine for the full lifecycle.

It now has:

- `recordingState`
  - foreground state for active recording UI
- `backgroundState`
  - background worker state for queued processing
- `pendingTranscriptionCount`
  - queue count visible to UI
- `queuedTranscriptionJobs`
  - in-memory FIFO queue

Important behavior:

- `startRecordingIfPossible()` returns `.started`, `.queueFull`, `.noModel`, or `.busy`
- `toggleRecord()` now means:
  - if currently recording: stop recording, create pending `Transcription`, snapshot settings, enqueue a job, close the recording panel
  - otherwise: attempt to start a fresh recording immediately

### 2. Jobs are snapshotted at enqueue time

`QueuedTranscriptionJob.swift` defines:

- `BackgroundTranscriptionState`
- `EnhancementContextSnapshot`
- `TranscriptionJobSnapshot`
- `QueuedTranscriptionJob`

The snapshot currently captures:

- append trailing space
- text formatting enabled
- auto-send state
- power mode name / emoji
- enhancement enabled flag
- selected prompt ID
- prompt list
- clipboard context
- screen-capture context

Reason:

- queued jobs should not accidentally pick up later UI/settings changes

### 3. `TranscriptionPipeline` runs from the snapshot

`TranscriptionPipeline.run(...)` now receives:

- `snapshot: TranscriptionJobSnapshot`
- `onBackgroundStateChange`

It uses the snapshot for:

- text formatting
- power mode metadata written to `Transcription`
- append trailing space
- auto-send
- enhancement prompt/context

It no longer dismisses the recorder UI itself.

### 4. Recorder panel closure and cleanup changed

`RecorderUIManager` was changed so that:

- it calls `engine.startRecordingIfPossible(...)` before showing the recorder
- `closePanelAfterRecordingStop()` only closes the recording panel
- cancellation of an active recording no longer destroys queued background work
- cleanup is skipped while background processing is still active

### 5. Missing processing UI was restored as a separate overlay

This is the new part for the user-reported regression.

New file:

- `VoiceS/Views/Recorder/BackgroundProcessingOverlayWindowManager.swift`

Current implementation:

- processing UI is now a separate `NSPanel`
- it reuses the existing `ProcessingStatusDisplay`
- it shows:
  - `Transcribing`
  - `Enhancing`
- it is controlled by `RecorderUIManager.syncPanels()`
- it is based on:
  - `backgroundState`
  - `isBackgroundProcessing`
  - `recorderType`
  - whether the recording panel is currently visible

Current placement logic:

- `mini`
  - background-only: near the bottom center
  - while recording: above the mini recorder
- `notch`
  - background-only: near the top center
  - while recording: shifted lower than the notch area

Important implementation detail:

- `BackgroundProcessingOverlayMode(backgroundState:isBackgroundProcessing:)`
  - returns `.enhancing` when background enhancement is active
  - returns `.transcribing` when background transcription is active
  - also returns `.transcribing` when `backgroundState == .idle` but queued/background work is still considered active

### 6. UI state provider was extended

`RecorderStateProvider` now exposes:

- `recordingState`
- `backgroundState`
- `partialTranscript`
- `pendingTranscriptionCount`
- `isBackgroundProcessing`

This gives the recorder UI enough information to distinguish active recording from background processing.

## Why the Regression Happened

The disappearance of the transcribing UI was caused by two changes happening together:

1. `recordingState` and `backgroundState` were split
2. the recorder panel started closing immediately after enqueue

Before:

- the recorder UI looked at `recordingState == .transcribing/.enhancing`

After the queue refactor:

- queued work moved to `backgroundState`
- `recordingState` goes back to `.idle` right after enqueue
- the recorder panel closes immediately

Result:

- the old processing UI no longer had any visible state path

The new overlay work is the fix for that.

## What I Tried

### Worked

1. Queue-based recording implementation

- enqueue on recording stop
- serial FIFO background worker
- recording can restart while earlier jobs still run

2. Snapshot-based post-processing

- queued jobs use enqueue-time settings instead of rereading global mutable state

3. Relaxed hotkey gating

- hotkey can start a new recording while background transcription is still running

4. Processing overlay restoration

- added a separate background processing overlay window
- wired `RecorderUIManager.syncPanels()` to keep recorder panel and processing overlay in sync
- wired `VoiceSEngine.processQueuedJobsIfNeeded()` to call `recorderUIManager?.syncPanels()` whenever `backgroundState` changes or completes

5. Build verification

This passes:

```bash
xcodebuild -project /Users/gdk/Projects/VoiceS/VoiceS.xcodeproj \
  -scheme VoiceS \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

6. Local packaging

This now passes:

```bash
make local
```

The packaged app was copied to:

```bash
/Users/gdk/Downloads/VoiceS.app
```

7. Overlay unit coverage

Added tests for:

- `BackgroundProcessingOverlayMode` defaulting to `.transcribing` when work is active
- `BackgroundProcessingOverlayMode` mapping `.enhancing` correctly

### Did Not Work / Problems Encountered

1. Initial local packaging failed once

First `make local` failure:

- `CodeSign ... VoiceS.app`
- failed because stale `Contents/PlugIns/VoiceSTests.xctest` was inside the Debug app bundle in DerivedData

Observed error:

- `bundle format unrecognized, invalid, or unsuitable`
- subcomponent:
  - `.../VoiceS.app/Contents/PlugIns/VoiceSTests.xctest`

What fixed it:

```bash
xcodebuild -project /Users/gdk/Projects/VoiceS/VoiceS.xcodeproj \
  -scheme VoiceS \
  -configuration Debug \
  clean
```

Then rerun:

```bash
make local
```

2. `xcodebuild test` is still not clean

Historically, and still effectively unresolved, test execution is not stable.

Previously observed failure:

- host app exits during test bootstrap
- not a compile error in the queue/overlay code

Attempted command:

```bash
xcodebuild -project /Users/gdk/Projects/VoiceS/VoiceS.xcodeproj \
  -scheme VoiceS \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_TESTABILITY=YES \
  MACOSX_DEPLOYMENT_TARGET=14.4 \
  -only-testing:VoiceSTests \
  test
```

Current practical status:

- I did not complete a clean `test` run in this session
- the command is still expensive because it rebuilds a lot of Debug dependencies
- this remains separate follow-up work

3. Runtime app verification is still missing

I did not manually launch the app and validate:

- A record/stop -> A transcribing overlay appears
- while A is transcribing, B recording UI appears and coexists with overlay
- background-only overlay matches old expected UX closely enough
- mini vs notch positioning looks correct on real screens

## Current Remaining Work

The highest-priority remaining work is runtime validation, not more refactoring.

### 1. Manually verify the user’s expected UI flow

Test the exact user scenario:

1. start recording A
2. stop A
3. confirm a processing overlay appears
4. while A is still processing, start recording B
5. confirm:
   - recording UI is visible
   - processing overlay is also visible
   - both are shown simultaneously
6. stop B and confirm queue continues normally

Do this for:

- `mini`
- `notch`

### 2. Check overlay positioning and visual quality

Likely things to inspect:

- whether the mini overlay sits too close / too far above the recorder
- whether the notch overlay overlaps awkwardly with the notch panel
- whether background-only notch positioning feels like the old UX
- whether any panel steals focus or interferes with typing

### 3. Confirm lifecycle behavior

Verify:

- `cancelRecording()` while background jobs exist
- `dismissMiniRecorder()` while background jobs exist
- queue finishing causes overlay to disappear
- one failed queued job does not block later jobs
- resources eventually clean up after the queue drains

### 4. Decide whether any overlay adjustments are needed

The current overlay is a separate compact panel.

If the user says it is not close enough to the original UI, likely follow-up options are:

- adjust size/spacing/styling of the overlay panel
- change notch overlay position
- make the overlay feel more like the old recorder HUD

I would avoid another major architecture change unless runtime testing shows this approach is clearly wrong.

## Known Risks / Open Questions

### 1. Recorder opening order still needs real-world validation

Current start flow:

- call `engine.startRecordingIfPossible(...)`
- only if it returns `.started`, set `isMiniRecorderVisible = true`

This avoids opening the recorder when the queue is already full, but it changed the old ordering.
It still needs manual validation that the recorder appears reliably on first hotkey press.

### 2. Background cleanup / model lifetime

`cleanupResourcesIfPossible()` only releases resources when:

- no active recording
- `backgroundState == .idle`
- queue empty

This is intentional, but still needs runtime verification.

### 3. Enhancement isolation is mostly, not fully, snapshotted

Current state:

- prompt list / selected prompt / clipboard / screen context are snapshotted
- selected text is still fetched later at enhancement execution time
- AI model identity is still read from the enhancement service at execution time

If strict per-job reproducibility matters, snapshot those too.

### 4. Queue persistence is still in-memory only

Implemented behavior on launch:

- any persisted `Transcription` row left in `pending` is marked failed with:
  - `"Transcription Failed: VoiceS was closed before processing finished."`

There is no resume-on-launch queue restoration.

## Recommended Next Steps

If you pick this up fresh, do this in order:

1. Run the packaged app:

```bash
open /Users/gdk/Downloads/VoiceS.app
```

2. Verify the exact user-reported scenario on `mini`

- A record/stop
- confirm processing overlay appears
- B record while A processes
- confirm both recorder + processing overlay are visible

3. Repeat on `notch`

4. If visuals are off, make the smallest possible overlay positioning/styling tweak

5. Repackage:

```bash
make local
```

If it fails with stale test bundles in the app again, run:

```bash
xcodebuild -project /Users/gdk/Projects/VoiceS/VoiceS.xcodeproj \
  -scheme VoiceS \
  -configuration Debug \
  clean
```

Then rerun:

```bash
make local
```

6. Only after runtime UX is confirmed, revisit `xcodebuild test` if needed

## Exact Commands Run In This Session

Build:

```bash
xcodebuild -project /Users/gdk/Projects/VoiceS/VoiceS.xcodeproj \
  -scheme VoiceS \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Attempted tests:

```bash
xcodebuild -project /Users/gdk/Projects/VoiceS/VoiceS.xcodeproj \
  -scheme VoiceS \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_TESTABILITY=YES \
  MACOSX_DEPLOYMENT_TARGET=14.4 \
  -only-testing:VoiceSTests \
  test
```

Clean after stale test bundle packaging issue:

```bash
xcodebuild -project /Users/gdk/Projects/VoiceS/VoiceS.xcodeproj \
  -scheme VoiceS \
  -configuration Debug \
  clean
```

Successful local package:

```bash
make local
```

Verification:

```bash
ls -la /Users/gdk/Downloads/VoiceS.app
du -sh /Users/gdk/Downloads/VoiceS.app
codesign -dv --verbose=2 /Users/gdk/Downloads/VoiceS.app
```

## Current Git State Relevant To This Task

Modified:

- `VoiceS/HotkeyManager.swift`
- `VoiceS/Services/AIEnhancement/AIEnhancementService.swift`
- `VoiceS/Services/PromptDetectionService.swift`
- `VoiceS/Views/Recorder/RecorderStateProvider.swift`
- `VoiceS/Whisper/RecorderUIManager.swift`
- `VoiceS/Whisper/TranscriptionModelManager.swift`
- `VoiceS/Whisper/TranscriptionPipeline.swift`
- `VoiceS/Whisper/VoiceSEngine.swift`
- `VoiceSTests/VoiceSTests.swift`

New:

- `VoiceS/Views/Recorder/BackgroundProcessingOverlayWindowManager.swift`
- `VoiceS/Whisper/QueuedTranscriptionJob.swift`

## If You Only Have Time For One Thing

Launch the app and verify the exact user complaint:

- A transcribing in the background
- B recording in the foreground
- both UIs visible at once

That is the remaining product question. The code builds and packages; the unresolved part is whether the runtime UX now matches what the user expects.
