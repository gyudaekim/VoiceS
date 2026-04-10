---
date: 2026-04-10
topic: transcribe-audio-history-list
---

# Transcribe Audio Tab — Inline History List

## Problem Frame

The Transcribe Audio tab currently displays the full transcription result text after processing completes. This is unnecessary — users don't need to read the full text inline. Instead, they need quick access to past transcription outputs (copy to clipboard, save as Markdown) and a clear record of what they've processed. The separate History window also shows file transcription results mixed with live recording results, which is confusing.

## Tab Layout

```
┌─────────────────────────────────────┐
│  Drop Zone / File Selection         │
│  (file picker, language, enhance)   │
│                                     │
│  ─── OR when processing ───         │
│  Progress bars (upload / transcribe) │
├─────────────────────────────────────┤
│  Recent Transcriptions              │
│                                     │
│  📄 meeting-notes.m4a    Apr 10     │
│     1:23:45  ✅  [📋] [💾]          │
│  📄 interview.wav        Apr 9      │
│     45:12    ✅  [📋] [💾]          │
│  📄 lecture.mp3           Apr 8      │
│     2:01:33  ✅  [📋] [💾]          │
│  ...                                │
│                                     │
│  [ View More ]                      │
└─────────────────────────────────────┘
```

## Requirements

**Tab Layout**
- R1. Remove the `TranscriptionResultView` (full text display) and `MarkdownDownloadButton` from the Transcribe Audio tab after transcription completes
- R2. The tab shows two sections: drop zone / file selection at top, history list below, separated by a divider
- R3. When a transcription is in progress, the progress UI replaces the drop zone (existing behavior), but the history list remains visible below. The newly completed transcription appears at the top of the list immediately upon completion.

**History List**
- R4. The history list shows the most recent file transcription records, sorted newest first
- R5. Each row displays: original audio filename, transcription date, audio duration, completion status indicator (completed/failed)
- R6. Each row has two small icon buttons: copy (clipboard) and save (Markdown file)
- R7. Copy button copies the best available text: enhanced text if present, otherwise original text
- R8. Save button exports the transcription as a `.md` file via save dialog, reconstructing markdown from the text field (wrapping in a `# Transcription` header — same pattern as existing `AnimatedSaveButton`)
- R9. The inline list shows a fixed number of recent items (5) without scrolling; the count is hardcoded, not dynamically measured
- R10. A "View More" button at the bottom opens a modal/sheet showing the full scrollable list with the same row format

**Data Model**
- R13. Add a `source: String?` field to the `Transcription` model with values `"file"` (Transcribe Audio tab) and `"recording"` (live recording). Default is `nil` for existing records.
- R14. Add an `originalFileName: String?` field to the `Transcription` model to store the user's original audio filename before it gets renamed to `transcribed_UUID.ext`
- R15. `AudioFileTranscriptionManager` must set `transcriptionStatus` to `.completed` when transcription finishes (currently left as `.pending`)
- R16. All new fields are optional with `nil` default — SwiftData lightweight migration handles this without a `VersionedSchema`

**History Separation**
- R11. File transcription results (source = `"file"`) must NOT appear in the separate History window
- R12. The History window continues to show live recording transcriptions only. All query sites in `TranscriptionHistoryView` (4 predicate branches in `cursorQueryDescriptor`, `selectAllTranscriptions`, `createLatestTranscriptionIndicatorDescriptor`) must filter by `source != "file"`.

## Success Criteria

- After transcription completes, users can immediately copy or save the result from the list row without reading the full text
- Past transcription results are accessible across app sessions without opening a separate window
- The History window is no longer cluttered with file transcription entries
- The tab is usable at default window size (950×730) without scrolling the inline list

## Scope Boundaries

- No changes to the progress UI (upload/transcription bars stay as-is)
- No changes to the History window's layout or functionality beyond filtering out file transcriptions
- The "View More" modal is a simple scrollable list, not a full-featured history browser
- Existing records with `source = nil` are treated as live recordings (backward compatible)
- No server markdown persistence — save button reconstructs from text field

## Key Decisions

- **Remove result text display**: Users don't need inline full-text — copy and save buttons on each row provide the same access with less clutter
- **Separate from History window**: File transcriptions and live recordings serve different workflows; mixing them in one History view is confusing
- **Copy = best available text**: Enhanced text takes priority when present, matching the existing copy behavior in `TranscriptionResultView`
- **`source` field on Transcription model**: Required to distinguish file transcriptions from live recordings for filtering (R4, R11, R12). Optional `String?` for lightweight migration compatibility.
- **`originalFileName` field**: `audioFileURL` contains `transcribed_UUID.ext`, not the user's original filename. A separate field is needed for display.
- **Reconstruct markdown, don't persist**: Save button wraps text in `# Transcription` header (existing `AnimatedSaveButton` pattern) rather than adding a `serverMarkdown` field. Simpler, no schema bloat.
- **Fixed inline count (5)**: Hardcoded rather than dynamically measured — avoids `GeometryReader` complexity for minimal UX difference.

## Outstanding Questions

### Deferred to Planning
- [Affects R9][Technical] Verify that 5 rows fit comfortably at 950×730 with drop zone above — adjust to 4 or 6 if needed during layout
- [Affects R12][Technical] Enumerate and update all query sites in `TranscriptionHistoryView` that need source filtering

## Next Steps

→ `/ce:plan` for structured implementation planning
