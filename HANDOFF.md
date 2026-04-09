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

---

# Cloudflare Tunnel: External Access for Qwen ASR API

## Goal

Expose the Qwen3-ASR-1.7B server running on gdk-server (internal network) to the public internet via Cloudflare Tunnel, so VoiceS can use the custom transcription model without VPN.

## Current Status: DONE (mostly)

The tunnel is live and working. External access is confirmed.

| Subdomain | Service | Port | Status |
|-----------|---------|------|--------|
| `mm.synrz.com` | Mattermost | 8065 | Working |
| `asr.synrz.com` | Qwen ASR API | 8000 | Working |

## Server Details

- **Server IP**: `10.78.151.244` (Tailscale VPN / internal)
- **OS**: Ubuntu 24.04.1 LTS
- **SSH**: `ssh gdk@10.78.151.244` (ed25519 key, no SSH config file — connects by IP)
- **GPU**: RTX 3080 Ti 12GB

## What Was Done

### 1. cloudflared installation

`cloudflared` was already authenticated and a tunnel already existed when we started (the user had previously set up `mm.synrz.com` for Mattermost).

- Binary installed at: `/home/gdk/cloudflared` (user download) AND `/usr/local/bin/cloudflared` (system copy)
- Version: `2026.3.0`
- Tunnel name: `magi-mattermost`
- Tunnel UUID: `047854ae-4193-4aad-aed2-3cd42af745b4`

### 2. Added ASR ingress rule

Updated `~/.cloudflared/config.yml` and `/etc/cloudflared/config.yml`:

```yaml
tunnel: 047854ae-4193-4aad-aed2-3cd42af745b4
credentials-file: /etc/cloudflared/047854ae-4193-4aad-aed2-3cd42af745b4.json

ingress:
  - hostname: mm.synrz.com
    service: http://localhost:8065
  - hostname: asr.synrz.com
    service: http://localhost:8000
  - service: http_status:404
```

### 3. DNS route added

```bash
~/cloudflared tunnel route dns magi-mattermost asr.synrz.com
```

This created a CNAME record in Cloudflare DNS pointing `asr.synrz.com` to the tunnel.

### 4. systemd service registered

Created `/etc/systemd/system/cloudflared.service`:

```ini
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel run magi-mattermost
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Enabled and started:

```bash
sudo systemctl daemon-reload
sudo systemctl enable cloudflared
sudo systemctl start cloudflared
```

Status: `active (running)`, 4 QUIC connections to ICN (Seoul) edge.

### 5. API key rotated

Old key `qwen-asr-local` was replaced with a 64-char random hex string.

- **New API key**: (see `~/qwen-asr-server/docker-compose.yml` on gdk-server → `API_KEY` env var)
- Set in: `~/qwen-asr-server/docker-compose.yml` → `API_KEY` environment variable
- The ASR container was recreated with `docker compose up -d`
- Old key `qwen-asr-local` is now invalid

The ASR server validates the key via `Authorization: Bearer <key>` header. See `~/qwen-asr-server/server.py` for the validation logic.

## What Worked

1. Installing cloudflared as a standalone binary (no sudo needed for download)
2. Reusing the existing `magi-mattermost` tunnel — just added a new ingress rule
3. `cloudflared tunnel route dns` for automatic CNAME creation
4. systemd service for persistence across reboots
5. API key rotation via docker-compose env var change + `docker compose up -d`

## What Didn't Work / Issues Encountered

1. **sudo password not available via SSH** — `sudo dpkg -i` failed because the SSH session can't prompt for passwords. Workaround: downloaded the binary directly to `~/cloudflared` instead of using the .deb package.

2. **SSH session drops when killing cloudflared** — running `pkill -f 'cloudflared tunnel run'` in the same SSH command chain as other commands caused exit code 255. Workaround: split into separate SSH calls (kill first, then start service in next call).

3. **nohup over SSH is unreliable** — `nohup ... &` over SSH sometimes causes the session to hang or return 255. Workaround: used single-quoted command (`'nohup ... &'`) which worked, then replaced with systemd for proper daemon management.

4. **Pasting multi-line commands in Claude Code** — a long sudoers one-liner broke when pasted across lines. Workaround: simplified to a short single-line command.

5. **Temporary NOPASSWD was needed for systemd setup** — added `gdk ALL=(ALL) NOPASSWD: ALL` to `/etc/sudoers.d/gdk-nopasswd`, then removed after setup was complete.

## Remaining Work

### 1. Update VoiceS app custom model settings

The user needs to update VoiceS settings:

- **API Endpoint**: `https://asr.synrz.com/v1/audio/transcriptions`
- **API Key**: (see `~/qwen-asr-server/docker-compose.yml` on gdk-server)

This is a manual step in the VoiceS macOS app UI (Settings → Custom Model).

### 2. Verify transcription works end-to-end over the external endpoint

After updating the app settings, test a real recording to confirm:

- Audio is sent to `https://asr.synrz.com/...`
- SSL/TLS works (Cloudflare handles this automatically)
- API key authentication passes
- Transcription result is returned correctly
- Latency is acceptable (should be similar since Cloudflare edge is in Seoul/ICN)

### 3. Consider Cloudflare Access (optional, deferred)

The user decided API key is sufficient for now. If stronger security is needed later:

- Cloudflare Zero Trust → Access → add an Application for `asr.synrz.com`
- Service Token auth (adds `CF-Access-Client-Id` / `CF-Access-Client-Secret` headers)
- This would require VoiceS app to support custom headers beyond the standard `Authorization` header

### 4. Keep config files in sync

Two copies of `config.yml` exist:

- `~/.cloudflared/config.yml` (user copy, used for `cloudflared tunnel` CLI commands)
- `/etc/cloudflared/config.yml` (system copy, used by systemd service)

If adding more ingress rules in the future, update BOTH files, then:

```bash
sudo systemctl restart cloudflared
```

### 5. Monitor tunnel health

```bash
# Check service status
sudo systemctl status cloudflared

# Check tunnel connections
~/cloudflared tunnel info magi-mattermost

# View recent logs
journalctl -u cloudflared --since "1 hour ago" --no-pager
```

## Key Files on gdk-server

| Path | Purpose |
|------|---------|
| `/home/gdk/cloudflared` | cloudflared binary (user copy) |
| `/usr/local/bin/cloudflared` | cloudflared binary (system copy) |
| `/home/gdk/.cloudflared/config.yml` | Tunnel config (user copy) |
| `/home/gdk/.cloudflared/cert.pem` | Cloudflare auth certificate |
| `/home/gdk/.cloudflared/047854ae-*.json` | Tunnel credentials |
| `/etc/cloudflared/config.yml` | Tunnel config (systemd copy) |
| `/etc/cloudflared/047854ae-*.json` | Tunnel credentials (systemd copy) |
| `/etc/systemd/system/cloudflared.service` | systemd unit file |
| `/home/gdk/qwen-asr-server/docker-compose.yml` | ASR server config (has API key) |
| `/home/gdk/qwen-asr-server/server.py` | ASR server code (has auth logic) |

## Docker Containers Running

```
qwen-asr-server        → :8000 (ASR API)
mattermost-server-app  → :8065 (Mattermost)
magi-control-plane     → :8080 (MAGI)
reddit-crawler-app-1   → (no port exposed)
reddit-crawler-db-1    → PostgreSQL (internal)
mattermost-server-postgres → PostgreSQL (internal)
mattermost-server-redis    → Redis (internal)
```

---

# Clipboard / Silent Failure Handoff (2026-04)

## Goal

Fix two user-reported bugs:

1. **Bug #1 — previous clipboard contents get pasted instead of transcription.**
   When the user has something already copied to the clipboard before running an STT session, sometimes the old clipboard item is pasted into the target app instead of the newly transcribed text.

2. **Bug #2 — silent failure.**
   Sometimes the recording UI reports the session as completed normally, but in reality something failed and nothing is inserted at the cursor. The user sees no error.

Both are root-cause fixed in this session. Runtime validation in the actual app is the remaining work.

## Analysis File

The full root-cause analysis, including timelines, race conditions, and file:line references, is saved at:

```
/Users/gyudaekim/.claude/plans/nested-tickling-dragon.md
```

If you are resuming this work, that file is worth a quick read — it is the "why" behind every change below.

## Root Causes Identified

### Bug #1 root causes (in priority order)

1. **Clipboard restore timer fires before the target app has processed Cmd+V.**
   `CursorPaster.pasteAtCursor()` was scheduling clipboard restoration with a floor of `max(userPref, 0.25)` seconds. Electron/web-based apps (Notion, Slack, VS Code, Discord, Chrome text fields), remote desktops, and slow web text areas routinely take more than 250 ms to actually read the pasteboard after a Cmd+V event. When restore fired first, the pasteboard was already reverted to the user's previous content, so the target app read the **previous** clipboard item.

2. **No verification that the clipboard write actually committed.**
   `ClipboardManager.setClipboard()` called `clearContents()` + `setString()` and always returned `true`. Neither the `Bool` return of `setString()` nor `NSPasteboard.changeCount` was checked. A silent write failure would cause the subsequent Cmd+V to paste whatever was in the clipboard before.

3. **Queue refactor introduced cross-job clipboard contamination.**
   After the queue-based recording refactor, multiple jobs can run back-to-back in the background worker. An in-flight restore from an earlier job could still be pending when the next `pasteAtCursor()` call saved its "original clipboard", so the "original" it captured was actually stale or wrong.

### Bug #2 root causes

| Where | What happens | User sees |
|---|---|---|
| `TranscriptionPipeline.swift:84` | After trim, no `isEmpty` check. Whisper returns `""` for silent audio → pipeline marks as `.completed` and pastes empty string. | "Completed" UI, nothing pasted. |
| `CursorPaster.swift:80-82` | `AXIsProcessTrusted()` false → `logger.error` + silent return. macOS updates / resigning can silently revoke this permission. | "Completed" UI, nothing pasted. |
| `CursorPaster.swift:85-87` | `TISCopyCurrentKeyboardInputSource()` returns nil → silent return. | "Completed" UI, nothing pasted. |
| `TranscriptionPipeline.swift:140-143` | Enhancement catch writes `"Enhancement failed: <error>"` into `transcription.enhancedText`, but `transcriptionStatus` is still set to `.completed`. Downstream history UI shows the error string as the transcript because `enhancedText` takes precedence over `text`. | History/list view displays error message as the transcript. |
| `CursorPaster.swift:71-73` | AppleScript paste failure → `logger.error` only, no user notification. | "Completed" UI, nothing pasted. |
| `TranscriptionPipeline.swift:158` | `.transcriptionCompleted` notification posted **before** the paste was even attempted. UI flips to "done" ~100 ms before paste runs. | UI success state decoupled from actual paste. |
| `NotificationManager` | Exists as toast infrastructure, but was never called from any paste / pipeline error path. | All failures invisible. |

## Files Changed

- `VoiceS/ClipboardManager.swift` — verify writes via `changeCount` + readback
- `VoiceS/CursorPaster.swift` — return a `PasteResult` enum, raise restore delay floor, flush in-flight restore between jobs
- `VoiceS/Whisper/TranscriptionPipeline.swift` — handle empty transcripts, surface all failure modes via `NotificationManager`, reorder `.transcriptionCompleted` notification to happen after paste

No other files were touched. No new files were added.

## What Was Changed, In Detail

### `VoiceS/ClipboardManager.swift`

`setClipboard(_:transient:)` is now `@discardableResult` and performs a real verification instead of always returning `true`:

```swift
let beforeChangeCount = pasteboard.changeCount
pasteboard.clearContents()
let didWriteString = pasteboard.setString(text, forType: .string)
// ... source / transient tags ...
let didBumpChangeCount = pasteboard.changeCount > beforeChangeCount
guard didWriteString && didBumpChangeCount else { return false }
if pasteboard.string(forType: .string) != text { return false }
return true
```

Three conditions must hold before the caller is told the write succeeded:

1. `setString` Bool return is true.
2. `changeCount` actually incremented (which only happens when the pasteboard server accepts the write).
3. Reading the pasteboard back returns exactly the string we just wrote (catches races with other apps holding the pasteboard).

`copyToClipboard(_:)` was also marked `@discardableResult` to match. All existing call sites continue to work: `LastTranscriptionService.swift:41` still captures the `Bool` return, the `let _ = ...` sites in `AnimatedCopyButton.swift` and `TranscriptionDetailView.swift` are now slightly redundant but still valid.

### `VoiceS/CursorPaster.swift`

New top-level enum:

```swift
enum PasteResult {
    case succeeded
    case clipboardWriteFailed
    case accessibilityDenied
    case inputSourceUnavailable
    case appleScriptFailed(String)
}
```

`CursorPaster.pasteAtCursor(_:)` now:

- Is `@discardableResult` and returns `PasteResult`.
- Has a new class-level static: `private static var pendingRestoreWorkItem: DispatchWorkItem?`.
- At the top of the function, if there is still an in-flight restore from a previous paste, it cancels it and runs it synchronously (`pending.perform()`) so we never save "the previous transcript" as "the original clipboard" of this paste.
- Calls `ClipboardManager.setClipboard(text, transient: shouldRestoreClipboard)` and, if it returns `false`, bails out with `.clipboardWriteFailed` **without** dispatching Cmd+V. This is the critical Bug #1 defense: if the write didn't commit, we refuse to paste instead of pasting whatever stale content was there.
- Calls `pasteUsingAppleScript()` or `pasteFromClipboard()` synchronously (no longer wrapped in `DispatchQueue.main.asyncAfter(+0.05)`, because the old 50 ms delay existed only to "ensure the clipboard is set" — that responsibility is now owned by `setClipboard`'s verification).
- Schedules clipboard restoration in a `DispatchWorkItem` that it also stores in `pendingRestoreWorkItem`, so the next paste can flush it.
- Uses a new minimum restore delay:
  ```swift
  private static let minimumRestoreDelay: TimeInterval = 1.2
  ```
  That is, `max(UserDefaults.clipboardRestoreDelay, 1.2)`. The old floor was 0.25 s, which was the primary cause of Bug #1 on slow / Electron-based target apps.

`pasteUsingAppleScript()` now returns `PasteResult`. On AppleScript error, it extracts `NSAppleScriptErrorMessage` and returns `.appleScriptFailed(message)`.

`pasteFromClipboard()` now returns `PasteResult`:

- `.accessibilityDenied` when `AXIsProcessTrusted()` is false
- `.inputSourceUnavailable` when `TISCopyCurrentKeyboardInputSource()` returns nil
- `.succeeded` after the CGEvent post is dispatched (actual delivery is async so we can't observe it further)

`pressEnter()` is unchanged.

### `VoiceS/Whisper/TranscriptionPipeline.swift`

The `do` block body was restructured:

1. **Audio duration and metadata are fetched once, up-front**, before branching on whether the transcript is empty. Duration / model name / power mode are now set for both the empty and non-empty paths.
2. **Empty transcript guard:**
   ```swift
   if text.isEmpty {
       transcription.text = ""
       transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
       logger.notice("⚠️ Empty transcript — skipping paste")
       NotificationManager.shared.showNotification(
           title: "No speech detected",
           type: .warning
       )
   } else { ... normal pipeline ... }
   ```
   This skips formatting, word replacement, enhancement, and paste entirely. `finalPastedText` stays nil so the paste block at the bottom is also skipped.
3. **Enhancement catch changed:**
   ```swift
   } catch {
       logger.error("Enhancement failed: \(error.localizedDescription, privacy: .public)")
       transcription.enhancedText = nil
       if shouldCancel() { await onCleanup(); return }
       NotificationManager.shared.showNotification(
           title: "AI enhancement failed — pasted raw transcript",
           type: .warning
       )
   }
   ```
   Key behavior change: `enhancedText` is now set to `nil` instead of `"Enhancement failed: <error>"`. This matters because every downstream view (`TranscriptionListItem`, `TranscriptionDetailView`, `LastTranscriptionService`, `TranscriptionResultView`) prefers `enhancedText` over `text` when present. Writing an error message into that field made history views display the error as if it were the transcript. Setting nil makes those views gracefully fall back to the raw `text`. The user is told about the enhancement failure via the toast instead.
4. **Top-level catch** (transcription itself failing) also now fires a `.error` toast "Transcription failed" in addition to setting the failed status.
5. **Paste block** now runs on the MainActor directly (no `DispatchQueue.main.asyncAfter`) and captures the `PasteResult`:
   ```swift
   try? await Task.sleep(nanoseconds: 50_000_000) // let recorder panel finish dismissing
   let pasteResult = CursorPaster.pasteAtCursor(
       textToPaste + (snapshot.appendTrailingSpace ? " " : "")
   )
   if snapshot.shouldAutoSend, case .succeeded = pasteResult {
       try? await Task.sleep(nanoseconds: 200_000_000)
       CursorPaster.pressEnter()
   }
   surfacePasteFailure(pasteResult)
   ```
   Auto-send Enter only fires when the paste actually succeeded — previously, Enter would be pressed even on failure, which could do bad things in the target app.
6. **`.transcriptionCompleted` notification moved to the end**, after the paste attempt. This closes the gap where UI would show "completed" ~100 ms before the paste was actually tried.
7. **New private helper** `surfacePasteFailure(_ result: PasteResult)` maps every non-success case to a `NotificationManager` toast. `.accessibilityDenied` gets a longer (5 s) duration so the user has time to read it.

## What Worked

1. **Clean build on the current main branch:**

   ```bash
   xcodebuild -project /Users/gyudaekim/Projects/VoiceS/VoiceS.xcodeproj \
     -scheme VoiceS \
     -destination 'platform=macOS' \
     CODE_SIGNING_ALLOWED=NO \
     build
   ```

   Result: `** BUILD SUCCEEDED **`. Zero warnings in the modified files (`CursorPaster.swift`, `ClipboardManager.swift`, `TranscriptionPipeline.swift`). Unrelated warnings in the rest of the project (`HotkeyManager.swift`, `MiniRecorderShortcutManager.swift`, `CustomSoundManager.swift`, `MenuBarManager.swift`) pre-exist this work.

2. **Return-type migration was non-breaking.** Existing callers of `ClipboardManager.setClipboard` / `copyToClipboard` and `CursorPaster.pasteAtCursor` still compile unchanged thanks to `@discardableResult`. Verified call sites:
   - `LastTranscriptionService.swift:41` — still captures `Bool`, still works.
   - `LastTranscriptionService.swift:72, 97, 131` — discards the result, allowed by `@discardableResult`.
   - `CursorPaster.swift:28` → now inside `pasteAtCursor`, uses the return.
   - `AnimatedCopyButton.swift:32`, `TranscriptionDetailView.swift:118` — `let _ = ...` pattern still valid.

3. **Root-cause analysis matched the code.** Two parallel Explore agents independently identified the same timing race and the same silent-return sites. The analysis is in `/Users/gyudaekim/.claude/plans/nested-tickling-dragon.md`.

## What Did Not Work / What Was Not Done

1. **No runtime validation in the actual app.** I did not launch the built app and reproduce either bug before/after the fix. The fix is based on source-level analysis and verified only by a successful build. You should:
   - Repackage with `make local` (which writes `~/Downloads/VoiceS.app`).
   - Run through the verification scenarios listed below.

2. **No tests added.** The project's `xcodebuild test` is historically flaky (documented earlier in this handoff under "Did Not Work / Problems Encountered, item 2"), so I did not add new tests to `VoiceSTests`. Good candidates for later:
   - `ClipboardManager.setClipboard` returning false when the pasteboard write doesn't commit (hard to simulate without a fake pasteboard).
   - `PasteResult` mapping from specific failure modes.
   - Empty-transcript → `.failed` + no paste.

3. **No preemptive accessibility permission check.** Bug #2 lists "move the `AXIsProcessTrusted()` check to recording-start time" as a good follow-up. I did not do this. Currently, the user will now get a clear toast when they actually try to paste, which solves the "silent" part, but they still won't discover the problem until after recording. A better UX would be to check at app launch / at first recording and block recording with a permission prompt.

4. **No changes to `VoiceSEngine.processQueuedJobsIfNeeded()`.** The queue worker still calls `pipeline.run(...)` without `do/catch`, but since `TranscriptionPipeline.run` no longer swallows failures silently — it surfaces them via `NotificationManager` directly — the queue worker does not need to handle errors itself. I left it alone to minimize the blast radius of this change. If you want stricter error propagation to the queue worker, convert `run` to `throws` (or return a `Result`) and thread failures up. Not necessary for the two reported bugs.

5. **No persisted-pref UI for the new `minimumRestoreDelay`.** The 1.2 s floor is hardcoded. If it turns out to be too conservative (users notice a visible clipboard flicker for too long), expose a setting. I did not add one.

6. **No verification of how `UserDefaults.standard.double(forKey: "clipboardRestoreDelay")` is surfaced in Settings UI.** Worth checking whether the existing Settings slider label still makes sense given the new 1.2 s floor. If the UI lets the user set it to 0.25 s thinking that will apply, they will be confused that it's actually clamped to 1.2 s. I did not touch Settings.

7. **Concurrency safety of `pendingRestoreWorkItem` was not hardened.** It is a plain `static var` on `CursorPaster`, not marked `@MainActor` or `nonisolated(unsafe)`. All current call paths touch it on the main thread (either from `@MainActor TranscriptionPipeline` or from `DispatchQueue.main.asyncAfter` in `LastTranscriptionService`), so there is no runtime race in practice. Swift 6 strict-concurrency mode might flag it; current project build mode does not. If the project later migrates to Swift 6, either mark `CursorPaster` `@MainActor` or the specific static `nonisolated(unsafe)`.

## Current Remaining Work

In priority order:

### 1. Repackage and run the app

```bash
cd /Users/gyudaekim/Projects/VoiceS
make local
open ~/Downloads/VoiceS.app
```

If `make local` fails due to the stale test bundle issue documented above, run:

```bash
xcodebuild -project /Users/gyudaekim/Projects/VoiceS/VoiceS.xcodeproj \
  -scheme VoiceS -configuration Debug clean
make local
```

### 2. Bug #1 runtime validation

The key matrix is **target app × clipboard-restore setting × paste mechanism**.

Scenarios (repeat each with a distinct known string in the clipboard beforehand, e.g. `ITEM_A`):

1. Target apps to try, in order of likelihood to reveal the bug:
   - Notion (Electron, slow — the original repro likely comes from here or similar)
   - Slack
   - VS Code
   - Discord
   - Safari web text field (e.g. Google search box)
   - Native TextEdit (fast, hardest to reproduce the bug on)

2. Clipboard restore setting:
   - `restoreClipboardAfterPaste = true` (default? check)
   - `restoreClipboardAfterPaste = false`

3. Paste mechanism:
   - CGEvent path (`useAppleScriptPaste = false`)
   - AppleScript path (`useAppleScriptPaste = true`)

For each: verify
- transcription result is pasted (not `ITEM_A`)
- clipboard is eventually restored to `ITEM_A` when restoration is on
- no visible flicker or weird interaction with the target app

If any slow app still occasionally pastes the stale item, the 1.2 s floor might need to go higher, or we should adopt a `changeCount`-polling strategy where we wait for the pasteboard to be read by the target (harder to detect robustly).

### 3. Bug #2 runtime validation

1. **Empty transcript case.** Start a recording, stay silent, stop. Expected: "No speech detected" warning toast. Nothing pasted. History entry marked as failed.

2. **Accessibility revoked case.** System Settings → Privacy & Security → Accessibility → toggle VoiceS off. Record + transcribe. Expected: "Accessibility permission required for VoiceS to paste" error toast (5 s). Toggle it back on.

3. **Enhancement failure case.** Easiest way to force this: disable network briefly, or point the enhancement service at an unreachable endpoint. Expected: raw transcript gets pasted, a warning toast says "AI enhancement failed — pasted raw transcript".

4. **Happy path regression.** Record a normal sentence with clipboard content set. Verify the transcription pastes cleanly and no toast is shown.

5. **Queue behavior regression.** Start recording A, stop it, immediately start recording B while A is still transcribing in the background. Verify both UIs work (per the earlier queue-work handoff) AND that neither job leaks clipboard state into the other.

### 4. If visuals / toasts are ugly

All new toasts use the existing `AppNotificationView` component (see `VoiceS/Notifications/AppNotificationView.swift`). Types used:

- `.warning` for empty transcript, AI enhancement failure
- `.error` for paste failures (accessibility, input source, AppleScript, clipboard write, transcription itself)

If the user finds the new warnings too aggressive or the wording wrong, edit the strings inside `TranscriptionPipeline.swift` (two spots: in the `do` block and in `surfacePasteFailure`).

### 5. Consider follow-ups

Optional but recommended; not required for the two reported bugs:

- Preemptive `AXIsProcessTrusted()` check at app launch, with a modal prompting the user to grant it.
- Thread paste result up to the queue worker so `VoiceSEngine` can track per-job outcomes (currently the worker never sees the paste result).
- Add a Settings UI slider / help text matching the new 1.2 s restore delay floor.

## Exact Commands Run In This Session

Build:

```bash
xcodebuild -project /Users/gyudaekim/Projects/VoiceS/VoiceS.xcodeproj \
  -scheme VoiceS \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Result: `** BUILD SUCCEEDED **`.

No `make local`, no `xcodebuild test`, no app launch was run in this session. The next agent should do those.

## Git State Relevant To This Task

Modified in this session (on top of whatever was already uncommitted from the earlier queue work):

- `VoiceS/ClipboardManager.swift`
- `VoiceS/CursorPaster.swift`
- `VoiceS/Whisper/TranscriptionPipeline.swift`
- `HANDOFF.md` (this section)

No new files added. No files deleted.

## If You Only Have Time For One Thing (2)

Launch the packaged app and reproduce **Bug #1** in Notion or Slack:

1. Copy `ITEM_A` to clipboard.
2. Record a sentence in VoiceS.
3. Verify the sentence — not `ITEM_A` — lands in the target app.
4. Verify clipboard reverts to `ITEM_A` after a beat.

If that works in Notion / Slack / VS Code, the hardest case is covered. Bug #2 surface changes are low-risk and mostly about toast copy.

---

# License / Trial / "VoiceS Local" Tab Removal Handoff (2026-04)

## Goal

Completely remove the **entire license / trial / activation concept** from the VoiceS codebase. The user started by asking to remove the bottom-most sidebar tab labeled "VoiceS Local" (which contained Change Log / Discord / Email Support links), but after clarification the scope expanded to a full rip-out of the licensing system. The intent is that every user is implicitly "Pro" with all features always available — no trial countdown, no license key entry, no PRO badge, no upgrade promotions, no Polar.sh API calls, no Keychain-stored license data, no trial-expired text injection into pasted transcriptions.

## Analysis File

Full root-cause analysis, file inventory, and implementation plan is at:
`/Users/gyudaekim/.claude/plans/nested-tickling-dragon.md`

That file is the source of truth for *what* was planned. This section documents *what was done*.

## Scope Decisions (from user)

Three clarification questions were asked and answered:

1. **Trial banner buttons in MetricsView?** → "배너 자체도 제거하고 그 다음에 라이센스 키라는 컨셉 자체를 아예 전체적인 코드에서 제거하고 싶어." (Remove the banner entirely, and then remove the license key concept from the code entirely.)
2. **Related files?** → "관련 파일도 함께 삭제" (Delete related files too.)
3. **Promotional text elsewhere?** → "관련 프로모션도 모두 제거" (Remove all related promotions.)

This turned a ~6-line sidebar change into a full ~500-line refactor.

## Project Format Discovery (Critical Enabler)

`VoiceS.xcodeproj/project.pbxproj` uses **`PBXFileSystemSynchronizedRootGroup`** (Xcode 16+ new format), which means the Xcode project auto-discovers files from the filesystem. **This meant I could `rm` files without manually editing `project.pbxproj`** — Xcode automatically removes them from the build target. If a future refactor adds/removes files, rely on this and skip the pbxproj dance.

Verified via:
```
grep -n "PBXFileSystemSynchronizedRootGroup" VoiceS.xcodeproj/project.pbxproj
```

## Files Deleted (9 total)

```
VoiceS/Models/LicenseViewModel.swift                                 (194 lines) — state machine, LicenseState enum, trial/activated logic, Polar API coordination
VoiceS/Services/LicenseManager.swift                                 (126 lines) — Keychain wrapper: license key, trial start date, activation ID; includes UserDefaults→Keychain migration
VoiceS/Services/PolarService.swift                                   (~200 lines) — Polar.sh API: POST /v1/license-keys/validate and /v1/license-keys/activate; hardcoded Bearer token
VoiceS/Services/Obfuscator.swift                                     (— lines) — only used by LicenseManager (line 100–115) and PolarService (line 51); orphaned after their deletion
VoiceS/Views/LicenseManagementView.swift                             (~270 lines) — the "VoiceS Local" tab body: hero section, license key field, purchase button, Changelog/Discord/Email Support/Docs/Tip Jar buttons
VoiceS/Views/LicenseView.swift                                       — legacy alternate license view, had no call sites
VoiceS/Views/Components/TrialMessageView.swift                       — the banner component with enum MessageType { .warning, .expired, .info }
VoiceS/Views/Components/ProBadge.swift                               — 18-line "PRO" badge component (only used in its own #Preview)
VoiceS/Views/Metrics/DashboardPromotionsSection.swift                — "Unlock VoiceS Local For Less" card + Affiliate Program card
```

Single command used:
```
rm -v VoiceS/Models/LicenseViewModel.swift VoiceS/Services/LicenseManager.swift VoiceS/Services/PolarService.swift VoiceS/Services/Obfuscator.swift VoiceS/Views/LicenseManagementView.swift VoiceS/Views/LicenseView.swift VoiceS/Views/Components/TrialMessageView.swift VoiceS/Views/Components/ProBadge.swift VoiceS/Views/Metrics/DashboardPromotionsSection.swift
```

## Files Modified (8 total)

### 1. `VoiceS/Views/ContentView.swift`

Six surgical edits:

- `enum ViewType`: removed `case license = "VoiceS Local"`
- Icon switch: removed `case .license: return "checkmark.seal.fill"`
- Removed `@StateObject private var licenseViewModel = LicenseViewModel()` from the struct
- Removed the 9-line PRO badge block in the sidebar header (`if case .licensed = licenseViewModel.licenseState { Text("PRO")... }`)
- `.navigateToDestination` notification handler: removed `case "VoiceS Local": selectedView = .license`
- `detailView(for:)` switch: removed `case .license: LicenseManagementView()`

The switch over `ViewType` in `detailView(for:)` is now exhaustive again because the enum case was also removed — compiler-checked.

### 2. `VoiceS/Views/MetricsView.swift`

Completely rewritten (previously ~52 lines with trial banner logic, now 14 lines). New full content:

```swift
import SwiftUI
import SwiftData
import Charts
import KeyboardShortcuts

struct MetricsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var hotkeyManager: HotkeyManager

    var body: some View {
        MetricsContent(modelContext: modelContext)
            .background(Color(.controlBackgroundColor))
    }
}
```

The wrapping `VStack`, `licenseViewModel`, `TrialMessageView` conditional rendering, and `.padding()` were all removed. `hotkeyManager` is kept (still needed as `@EnvironmentObject` even if unused here, since removing it might affect the environment chain — left as-is for safety).

### 3. `VoiceS/Views/Metrics/MetricsContent.swift`

- Removed `let licenseState: LicenseViewModel.LicenseState` property (line 8)
- Removed the `HStack(alignment: .top, spacing: 18) { HelpAndResourcesSection(); DashboardPromotionsSection(licenseState: licenseState) }` wrapper (lines 29–32)
- Replaced with standalone `HelpAndResourcesSection()`

Before:
```swift
HStack(alignment: .top, spacing: 18) {
    HelpAndResourcesSection()
    DashboardPromotionsSection(licenseState: licenseState)
}
```
After:
```swift
HelpAndResourcesSection()
```

**Known layout risk:** `HelpAndResourcesSection` was previously sized to fill half of the row (next to the promo card). Standalone it may render at full width or look awkward depending on its internal `.frame` / `.maxWidth` settings. This was NOT visually verified in the running app. See "Not Done" section below.

### 4. `VoiceS/Whisper/TranscriptionPipeline.swift`

- Removed `var licenseViewModel: LicenseViewModel` property
- Removed `self.licenseViewModel = LicenseViewModel()` from `init`
- Removed the trial-expired paste prefix block (previously lines 188–195):
  ```swift
  if case .trialExpired = licenseViewModel.licenseState {
      textToPaste = """
          Your trial has expired. Upgrade to VoiceS Local at github.com/gdkim/VoiceS
          \n\(textToPaste)
          """
  }
  ```
- Changed `if var textToPaste = finalPastedText` → `if let textToPaste = finalPastedText` (no longer needs mutability)

This is compatible with the clipboard / silent-failure fix from the previous session (see above in this HANDOFF).

### 5. `VoiceS/Whisper/VoiceSEngine.swift`

- `setupNotifications()`: removed the `.licenseStatusChanged` observer registration; kept `.promptDidChange` observer
- Removed `@objc func handleLicenseStatusChanged() { pipeline.licenseViewModel = LicenseViewModel() }`

After change:
```swift
func setupNotifications() {
    NotificationCenter.default.addObserver(
        self,
        selector: #selector(handlePromptChange),
        name: .promptDidChange,
        object: nil
    )
}
```

### 6. `VoiceS/Notifications/AppNotifications.swift`

Removed one line: `static let licenseStatusChanged = Notification.Name("licenseStatusChanged")`

### 7. `VoiceS/Services/SystemInfoService.swift`

- Removed `License Status: \(getLicenseStatus())` line from `getSystemInfoString()` template
- Removed the entire `private func getLicenseStatus() -> String { ... }` method (which was the ONLY remaining caller of `LicenseManager.shared` after the deletions)

### 8. `VoiceS/Services/UserDefaultsManager.swift`

- Removed `static let affiliatePromotionDismissed = "VoiceSAffiliatePromotionDismissed"` from `Keys` enum
- Removed the `var affiliatePromotionDismissed: Bool { get/set }` extension computed property (5 lines)

## Files NOT Touched (intentional)

- `VoiceS/Services/KeychainService.swift` — **STILL USED** by `VoiceS/Services/APIKeyManager.swift:9` (`private let keychain = KeychainService.shared`). Verified via grep. Leaving it intact.
- `VoiceS/VoiceSApp.swift` — no license bootstrap was ever there.
- `VoiceS/Services/Obfuscator.swift` — deleted in the file sweep (only LicenseManager/PolarService used it).
- Tests — no license-related test files exist.
- `LICENSE.md` at repo root — this is the OSS license of the project, totally unrelated to trial/activation code.
- `#if LOCAL_BUILD` feature flag — only existed inside `LicenseViewModel.swift`, disappeared with the file.

## Dead Symbol Sweep (Passed)

After all edits:
```
grep -rn "LicenseViewModel|LicenseState|LicenseManager|PolarService|TrialMessageView|ProBadge|DashboardPromotionsSection|licenseStatusChanged|VoiceS Local|affiliatePromotion|Obfuscator" VoiceS --include="*.swift"
```
→ **0 matches**

String literal `"VoiceS Local"` is also gone from the entire codebase.

## Build Verification (Passed)

```
xcodebuild -project /Users/gyudaekim/Projects/VoiceS/VoiceS.xcodeproj \
  -scheme VoiceS \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Result: **`** BUILD SUCCEEDED **`**

Warnings: only two pre-existing ones in `AudioDeviceManager.swift:512` and `CoreAudioRecorder.swift:756` about `UnsafeMutableRawPointer` to `Optional<T>` — completely unrelated to this refactor, present before any edits.

No new warnings, no errors, no dangling references. The compiler exhaustiveness check on `switch viewType` in `ContentView.swift` confirmed the enum case removal is consistent.

## What Worked

1. **File-system-synchronized Xcode project format** — `rm` 9 files + no pbxproj surgery needed. This was the biggest risk mitigator.
2. **Compiler-driven dead code detection** — removing `LicenseViewModel.swift` itself forced the compiler to flag every remaining reference, which I then cleaned up one by one. No guesswork.
3. **Thorough Phase 1 inventory** — the Explore agent produced a complete file+line map of every license reference, so Phase 2 was pure mechanical editing with no surprises.
4. **Small atomic Edit calls** — each edit was independently verifiable in the file. No large multi-hunk rewrites except `MetricsView.swift` (which was 52 → 14 lines and simpler to fully rewrite via Write).

## What Did NOT Work / Was NOT Done

### 1. Runtime validation — **NOT DONE**

The build passed but the app was **not launched**. I did NOT run `make local` and I did NOT open `~/Downloads/VoiceS.app` to visually verify:

- Sidebar now has 10 items and no "VoiceS Local"
- Dashboard / MetricsView has no trial banner
- `HelpAndResourcesSection()` renders correctly standalone (the one known layout risk — see below)
- Sidebar header no longer shows "PRO" badge
- Transcription → paste still works end-to-end
- `Copy System Info` button output no longer includes `License Status:` line
- `promptDidChange` still reaches the whisper context (since `setupNotifications()` was edited)

**Next agent should do this first.** Commands:
```
cd /Users/gyudaekim/Projects/VoiceS && make local
open ~/Downloads/VoiceS.app
```

### 2. `MetricsContent` layout after `DashboardPromotionsSection` removal

`HelpAndResourcesSection` was originally rendered inside an `HStack(alignment: .top, spacing: 18)` alongside `DashboardPromotionsSection`, implying it was sized to ~half-width. Now it's standalone. **I did not read `HelpAndResourcesSection.swift` to check whether it uses `.frame(maxWidth: .infinity)` or a fixed/flexible internal width.**

Possible outcomes:
- Best case: it already uses `.frame(maxWidth: .infinity)` and fills the row naturally.
- Medium case: it's left-aligned at intrinsic width and looks stranded.
- Worst case: it hard-codes a half-row width and looks tiny.

**Action if it looks bad:** wrap in `HStack { HelpAndResourcesSection(); Spacer() }` or add `.frame(maxWidth: .infinity, alignment: .leading)` at the call site in `MetricsContent.swift:~29`.

### 3. Leftover UserDefaults and Keychain data — **INTENTIONALLY NOT CLEANED**

Existing users upgrading to this build will still have stale data in storage:

UserDefaults:
- `VoiceSHasLaunchedBefore`
- `VoiceSLicenseRequiresActivation`
- `VoiceSActivationsLimit`
- `VoiceSAffiliatePromotionDismissed`

Keychain:
- `voiceink.license.key`
- `voiceink.license.trialStartDate`
- `voiceink.license.activationId`
- The `LicenseKeychainMigrationCompleted` UserDefault flag

No code reads these keys anymore, so they are harmless — but they sit around until the app is uninstalled. If the user wants a clean-up migration, it would go in `VoiceSApp.init` or a one-shot block gated on a new `LicenseCleanupCompleted` UserDefault key. **Out of scope for this PR.**

### 4. `@EnvironmentObject hotkeyManager` in `MetricsView`

The new `MetricsView` still declares `@EnvironmentObject private var hotkeyManager: HotkeyManager` even though the body doesn't reference it. Removing it might be fine (the environment is still populated at the parent level), but there's some subtle SwiftUI behavior around environment propagation that I didn't want to risk without runtime checks. **Left as-is.** A follow-up agent can delete the unused declaration if they verify it doesn't break anything.

### 5. `hotkeyManager` + other unused imports

I did not audit for other imports that became unused as a result of the edits. A cleanup pass with `swift-format` or manual review could trim `import Charts` / `import KeyboardShortcuts` in `MetricsView.swift` if they are no longer needed (Charts might still be used transitively via `MetricsContent`). **Not done.**

### 6. Promotional text in `heroSection` / elsewhere

The inventory focused on obvious license strings. There *may* be other "Upgrade" / "Pro" / "Get Premium" style copy buried in comments or string literals that weren't caught. `grep` for those specific words surfaced no hits, but the net was tight. If the user finds stray "upgrade" CTAs somewhere, handle ad-hoc.

### 7. Git — **NOT COMMITTED**

No git commit was made. This session:
- Did not stage anything
- Did not create a branch
- Did not commit

The working tree has ~17 file changes (9 deletes + 8 modifies). The previous session's clipboard/silent-failure fixes may ALSO still be uncommitted — verify with `git status` before making commit decisions.

## Current Git State (Approximate)

```
deleted:    VoiceS/Models/LicenseViewModel.swift
deleted:    VoiceS/Services/LicenseManager.swift
deleted:    VoiceS/Services/PolarService.swift
deleted:    VoiceS/Services/Obfuscator.swift
deleted:    VoiceS/Views/LicenseManagementView.swift
deleted:    VoiceS/Views/LicenseView.swift
deleted:    VoiceS/Views/Components/TrialMessageView.swift
deleted:    VoiceS/Views/Components/ProBadge.swift
deleted:    VoiceS/Views/Metrics/DashboardPromotionsSection.swift
modified:   VoiceS/Views/ContentView.swift
modified:   VoiceS/Views/MetricsView.swift
modified:   VoiceS/Views/Metrics/MetricsContent.swift
modified:   VoiceS/Whisper/TranscriptionPipeline.swift
modified:   VoiceS/Whisper/VoiceSEngine.swift
modified:   VoiceS/Notifications/AppNotifications.swift
modified:   VoiceS/Services/SystemInfoService.swift
modified:   VoiceS/Services/UserDefaultsManager.swift
modified:   HANDOFF.md  (this section)
```

Plus whatever is still uncommitted from the earlier clipboard/silent-failure session (`ClipboardManager.swift`, `CursorPaster.swift`, more in `TranscriptionPipeline.swift`). Run `git status` to see the full picture.

## Exact Commands Run

```
# Phase 1: delete files
rm -v VoiceS/Models/LicenseViewModel.swift VoiceS/Services/LicenseManager.swift \
      VoiceS/Services/PolarService.swift VoiceS/Services/Obfuscator.swift \
      VoiceS/Views/LicenseManagementView.swift VoiceS/Views/LicenseView.swift \
      VoiceS/Views/Components/TrialMessageView.swift VoiceS/Views/Components/ProBadge.swift \
      VoiceS/Views/Metrics/DashboardPromotionsSection.swift

# Phase 2: file edits via the Edit tool (not reproducible as shell commands — see per-file section above)

# Phase 3: dead symbol sweep
grep -rn "LicenseViewModel\|LicenseState\|LicenseManager\|PolarService\|TrialMessageView\|ProBadge\|DashboardPromotionsSection\|licenseStatusChanged\|VoiceS Local\|affiliatePromotion\|Obfuscator" VoiceS --include="*.swift"
# → 0 matches

# Phase 4: build verification
xcodebuild -project /Users/gyudaekim/Projects/VoiceS/VoiceS.xcodeproj \
  -scheme VoiceS -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
# → ** BUILD SUCCEEDED **
```

**NOT run:** `make local`, `open ~/Downloads/VoiceS.app`, any test target, any git command.

## Current Remaining Work (Priority Order)

1. **Runtime smoke test.** `make local` + open the packaged app. Walk the checklist in "What Did NOT Work #1".
2. **Visually verify Dashboard layout** — specifically that `HelpAndResourcesSection` looks correct standalone. If it looks stranded or wrong-sized, apply the fix in "#2" above.
3. **Decide what to do with stale UserDefaults / Keychain data** ("#3" above). Either add a cleanup migration or document that it's left alone.
4. **Regression check `promptDidChange`** — change the transcription prompt in Settings and confirm it reaches the whisper context after the `setupNotifications()` edit.
5. **Commit the changes** (together with the previous session's clipboard fixes, or as separate commits — your call). Suggested split:
   - Commit A: clipboard + silent failure fixes (from the first HANDOFF section above)
   - Commit B: license / trial / VoiceS Local tab removal (this section)
6. **Optional follow-ups:**
   - Remove unused `@EnvironmentObject hotkeyManager` from the new `MetricsView`
   - Trim any now-unused imports in edited files
   - Run `xcodebuild test` if there's a test target

## If You Only Have Time For One Thing (3)

Launch the packaged app and walk the sidebar:

1. `cd /Users/gyudaekim/Projects/VoiceS && make local`
2. `open ~/Downloads/VoiceS.app`
3. Sidebar should show 10 items: Dashboard, Transcribe Audio, History, AI Models, Enhancement, (Power Mode if enabled), Permissions, Audio Input, Dictionary, Settings. **No "VoiceS Local" at the bottom.**
4. App header should show just "VoiceS" — **no "PRO" badge**.
5. Click into Dashboard. **No trial banner, no "Unlock VoiceS Local For Less" card, no "Affiliate Program" card.**
6. Record a short clip and verify paste still works and that **no "Your trial has expired..." prefix appears.**

If those six things check out, the refactor is done.


---

# Dashboard "Help & Resources" Section Removal Handoff (2026-04-10)

> Plan file reference: `/Users/gyudaekim/.claude/plans/nested-tickling-dragon.md` (overwritten with this task's plan)

## Goal

Remove the **Help & Resources** card from the Dashboard (Metrics) tab entirely. This is the block containing:
- Recommended Models
- YouTube Videos & Guides
- Documentation
- Feedback or Issues?

User request (Korean, verbatim): *"이거 태시보드 탭을 갔을 때 help and resources 란 섹션이 있고 recommended models, YouTube video and guides, documentation, feedback or issues 이 메뉴들이 있는데 이 섹션 help and resources 섹션을 통으로 없애고 싶어."*

Context: In the previous license-removal refactor, `DashboardPromotionsSection` was removed and `HelpAndResourcesSection` was left standing alone. The user now wants this section gone as well — the links pointed to external URLs (`github.com/gdkim/VoiceS/recommended-models`, `/docs`, `tryvoiceink` YouTube) that don't exist on this fork.

## Scope

Self-contained refactor. Only two touch points:

1. **Delete** `VoiceS/Views/Metrics/HelpAndResourcesSection.swift` (80 lines — the section's only implementation)
2. **Remove one line** `HelpAndResourcesSection()` from `VoiceS/Views/Metrics/MetricsContent.swift` (was on line 28 of the old file)

That's it. `EmailSupport.swift` was NOT deleted because `MenuBarView.swift` still uses `EmailSupport.openSupportEmail()`.

## Files Changed

### Deleted
- `VoiceS/Views/Metrics/HelpAndResourcesSection.swift`

### Modified
- `VoiceS/Views/Metrics/MetricsContent.swift` — removed the single-line `HelpAndResourcesSection()` call from the body `VStack`. Resulting structure inside the ScrollView's VStack:
  ```swift
  VStack(spacing: 24) {
      heroSection
      metricsSection

      Spacer(minLength: 20)

      HStack {
          Spacer()
          footerActionsView
      }
  }
  ```

### NOT touched
- `VoiceS/EmailSupport.swift` — still used by `MenuBarView.swift`
- `VoiceS/Views/MenuBarView.swift` — unrelated
- `project.pbxproj` — `PBXFileSystemSynchronizedRootGroup` format auto-syncs file deletions

## Verification Performed

### 1. Dead symbol sweep
```bash
grep -rn "HelpAndResourcesSection" VoiceS --include="*.swift"
```
Result: **0 matches**

### 2. Build
```bash
xcodebuild -project VoiceS.xcodeproj -scheme VoiceS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```
Result: **`** BUILD SUCCEEDED **`** on first attempt. No new warnings.

### 3. Runtime smoke test
**NOT performed.** The build succeeded but I did not launch the packaged app. The next agent (or user) should run:
```bash
make local
open ~/Downloads/VoiceS.app
```
And verify Dashboard now shows only:
- Hero card ("You have saved X with VoiceS")
- 4-card metric grid (Sessions / Words / WPM / Keystrokes Saved)
- `Copy System Info` pill button (bottom-right)

With **no** "Help & Resources" card between metrics and the Copy button.

## What Worked
1. **Compiler-driven verification** — single grep + single build confirmed the refactor was complete. The task was small enough that no Explore agents were needed.
2. **Plan-mode discipline** — overwrote the previous license-removal plan file before starting; ExitPlanMode → execution was clean.
3. **Surgical Edit** — the VStack context (`heroSection` + `metricsSection` + blank + `Spacer`) was unique enough that a single Edit matched. No file rewrite needed.

## What Did NOT Work / Loose Ends
1. **No runtime verification** — I did not visually confirm the Dashboard layout after the change. The hero + metric grid + footer should still look sensible with the middle section removed, but there's a small risk the vertical rhythm feels off (the `Spacer(minLength: 20)` now pushes the footer further down than before since the VStack is shorter).
2. **Nothing committed to git** — no commit made this session.
3. **`footerActionsView` positioning** — the `Copy System Info` button sits in an `HStack { Spacer(); footerActionsView }` which was originally below a denser layout. Worth checking it still looks intentional rather than orphaned.
4. **Empty-state view unchanged** — `emptyStateView` (shown when `totalCount == 0`) was never affected by this refactor and was not touched.

## Exact Commands Run This Session
```bash
rm /Users/gyudaekim/Projects/VoiceS/VoiceS/Views/Metrics/HelpAndResourcesSection.swift
# Edit MetricsContent.swift to remove the HelpAndResourcesSection() call
grep -rn "HelpAndResourcesSection" VoiceS --include="*.swift"  # 0 matches
xcodebuild -project VoiceS.xcodeproj -scheme VoiceS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build  # ** BUILD SUCCEEDED **
```

## Current Git State
Uncommitted changes from this session:
- Deletion: `VoiceS/Views/Metrics/HelpAndResourcesSection.swift`
- Modification: `VoiceS/Views/Metrics/MetricsContent.swift`

These are on top of the already-uncommitted license-removal refactor from the previous session (see the handoff section immediately above this one). **Neither refactor has been committed yet.** If the user wants discrete history, these are two logical commits:
1. License/Trial/"VoiceS Local" tab removal (9 deletes + 8 modifications)
2. Dashboard Help & Resources section removal (1 delete + 1 modification)

## Remaining Work For The Next Agent (in priority order)
1. **Smoke test the packaged app** — run `make local`, open the app, verify Dashboard tab layout looks clean and the sidebar/PRO-badge/trial-prefix items from the earlier refactor all pass. Six-step checklist from the previous handoff section still applies.
2. **Optional layout polish** — if Dashboard footer feels stranded, consider reducing `Spacer(minLength: 20)` or tightening `VStack(spacing: 24)`. Don't do this blind — look at the running app first.
3. **Git commits** — user hasn't explicitly asked, but two separate commits would keep history legible:
   - `refactor: remove license/trial concept and VoiceS Local sidebar tab`
   - `refactor: remove Help & Resources section from Dashboard`
4. **Decide on stale data cleanup** — UserDefaults/Keychain residue from the license removal is still listed as out of scope. Unchanged.

## If You Only Have Time For One Thing
Launch `make local` + `open ~/Downloads/VoiceS.app`. Click through Dashboard. If it looks right and a quick record/paste still works, both refactors are done from an end-user perspective and you can commit.
