---
date: 2026-04-10
topic: transcribe-queue-and-icons
---

# Transcribe Audio — Queue Support & Icon Polish

## Problem Frame

The inline history list (just shipped) has icons that are too small to click comfortably, and the download icon isn't visually distinct. More importantly, the tab only handles one file at a time — the user must wait for each transcription to finish before dropping the next file. Users want to drop multiple files at once and have them process sequentially, with clear status in the history list.

## Tab Layout (Updated)

```
┌─────────────────────────────────────────┐
│  Drop Zone  (always ready for next file │
│  after transcription starts)            │
├─────────────────────────────────────────┤
│  Transcriptions                         │
│                                         │
│  📄 meeting.m4a    Apr 10   ⏳  📋  ⬇  │  ← queued
│  📄 lecture.mp3    Apr 10   🔄  📋  ⬇  │  ← in progress
│  📄 notes.wav      Apr 10   ✅  📋  ⬇  │  ← completed
│  📄 old-file.m4a   Apr 9    ✅  📋  ⬇  │
│                                         │
│  [ View More ]                          │
└─────────────────────────────────────────┘
```

## Requirements

**Icon Size & Clarity**
- R1. Status, copy, and download icons use `.body` font size (not `.caption`) for comfortable click targets
- R2. Download button uses SF Symbol `"square.and.arrow.down"` — the standard macOS download icon, clearly distinct from copy
- R3. Copy button keeps `"doc.on.doc"` icon
- R4. Status icons are visually distinct per state: completed (green checkmark), failed (red X), in-progress (spinning/animated), queued (clock/hourglass)

**In-Progress & Queued Items in History List**
- R5. When transcription starts, the file immediately appears at the top of the history list with an in-progress status icon
- R6. The progress UI (upload bars, per-chunk bars) is shown INSIDE the in-progress row or directly above the list — not replacing the drop zone
- R7. Queued files (waiting to be processed) appear in the list with a queued/waiting status icon, above completed items
- R8. Sort order: in-progress first, then queued (in queue order), then completed/failed (newest first)

**Auto-Deselect on Start**
- R9. When transcription starts (or files are queued), the drop zone resets to its empty "drop here" state — ready for the next file immediately
- R10. The user does not need to wait for transcription to finish before dropping more files

**Multi-File Queue**
- R11. Drag-and-drop accepts multiple files simultaneously. Each file becomes a separate queued transcription job.
- R12. Files are processed sequentially in drop order — one at a time
- R13. All files in a batch use the language hint and enhancement settings that were active at drop time
- R14. Cancel button cancels the entire queue (current + all waiting). Individual cancel not supported.
- R15. If one file fails, skip it (mark as failed in list) and continue with the next queued file

**Data Model**
- R16. Queued and in-progress files must be represented in the list. Either create Transcription records immediately (with status `.queued` / `.inProgress`), or maintain a separate queue data structure that the list view merges with the `@Query` results.
- R17. `TranscriptionStatus` enum needs two new cases: `.queued` and `.inProgress` to support R4's four visual states. Currently only has `.pending`, `.completed`, `.failed`.

## Success Criteria

- User can drop 5 MP3 files at once → all 5 appear in history list (1 in-progress, 4 queued) → they process one by one → drop zone is ready for more files throughout
- Icons are large enough to click without precision targeting
- Download icon is immediately recognizable as "save/download"
- The progress UI for the current file is visible without replacing the drop zone

## Scope Boundaries

- No parallel transcription — files process one at a time (sequential queue)
- No per-file settings — all files in a batch share the same language/enhancement config
- No queue reordering or individual item cancellation
- No changes to the server API or strategy selection — queue is purely client-side orchestration
- Existing completed items in the history list are unaffected

## Key Decisions

- **Sequential queue, not parallel**: Transcription is CPU/network intensive. Processing one at a time avoids resource contention and keeps progress tracking simple.
- **Auto-deselect on start**: The drop zone should always be ready. Requiring manual deselect between files is friction.
- **Cancel = entire queue**: Simpler than per-item cancel. Users rarely need to selectively cancel from a batch.
- **Settings captured at drop time**: If user changes language hint between drops, the earlier batch keeps its original settings.

## Outstanding Questions

### Deferred to Planning
- [Affects R6][Technical] Whether the progress UI (upload/chunk bars) should be embedded inside the in-progress list row or shown as a separate section above the list. The row approach is cleaner but may be too compact for the two-bar layout.
- [Affects R16][Technical] Whether to create Transcription records immediately for queued files (simpler query, but records exist before transcription starts) or maintain a separate in-memory queue that merges with @Query results (cleaner data, but more complex view logic). The VoiceSEngine pattern creates records immediately.

## Next Steps

→ `/ce:plan` for structured implementation planning
