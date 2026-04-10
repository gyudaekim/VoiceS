---
date: 2026-04-10
topic: transcribe-progress-ui
---

# Transcribe Audio Progress UI Redesign

## Problem Frame

The Transcribe Audio tab shows a single progress bar that combines upload (0-50%) and server transcription (50-100%) into one bar. This is confusing: the upload phase shows "Uploading 12/45 MB" but the bar reads 14%, and the transcription phase never reaches visually meaningful progress values. The user expects two clearly separated phases with appropriate granularity.

## User Flow

```
File selected → Start Transcription
        │
        ▼
┌─────────────────────────┐
│  PHASE 1: Upload        │
│                         │
│  Uploading 12.5 / 45 MB│
│  [████████░░░░░░░] 28%  │  ← 0-100% of upload bytes
│                         │
│  [Cancel]               │
└─────────────────────────┘
        │ upload complete
        ▼
┌─────────────────────────┐
│  PHASE 2: Transcribing  │
│                         │
│  Chunk 3 / 17           │
│  [◄═══════════►] or     │  ← per-chunk: indeterminate (local)
│  [█████░░░░░░░░] 42%    │     or determinate (server)
│                         │
│  Overall                │
│  [████░░░░░░░░░░] 18%   │  ← total chunks completed
│                         │
│  ko detected            │
│  [Cancel]               │
└─────────────────────────┘
        │ all chunks done
        ▼
   Result + Download MD
```

## Requirements

**Phase 1 — Upload**
- R1. Upload phase shows a single dedicated progress bar with bytes sent / total bytes (e.g., "Uploading 12.5 / 45.3 MB")
- R2. Upload progress bar ranges 0-100% of the upload itself, not a fraction of overall progress
- R3. Upload phase UI replaces the current combined progress bar when the strategy is server-based (`QwenServerJobStrategy`)
- R4. For client-side chunking (local models), Phase 1 is skipped entirely — there is no upload

**Phase 2 — Transcribing**
- R5. Transcribing phase shows two stacked progress bars simultaneously
- R6. Top bar = per-chunk progress: shows transcription progress of the chunk currently being processed
- R7. Bottom bar = overall progress: shows completed chunks out of total (e.g., "Chunk 3 / 17", 18%)
- R8. Per-chunk bar behavior depends on the strategy:
  - Server path (`QwenServerJobStrategy`): determinate bar using `progress_percent` derived from server polling
  - Client path (`ClientChunkingStrategy`): indeterminate spinner with "Processing chunk N..." text
- R9. Overall bar is always determinate: `completed_chunks / total_chunks * 100`
- R10. Detected language label shown when available (e.g., "ko detected")

**Shared**
- R11. Cancel button visible in both phases
- R12. Phase transition (upload → transcribing) is automatic and visually clear — no user action needed

## Success Criteria

- Upload phase shows 0→100% tracking real bytes sent, not a fraction of combined progress
- User can distinguish "still uploading" from "server is transcribing"
- During transcription, user sees both per-chunk and overall progress simultaneously
- Small files (< 30s, single chunk) show a clean minimal UI without confusing empty bars

## Scope Boundaries

- No changes to the server API or polling contract
- No changes to `LongAudioProgress` data model (existing fields are sufficient)
- No changes to `ClientChunkingStrategy` or `QwenServerJobStrategy` progress callback structure — only the UI rendering changes
- Audio processing phase ("Processing audio file...") remains as-is (indeterminate, shown before Phase 1 or Phase 2)

## Key Decisions

- **Per-chunk bar for local models = indeterminate**: local transcription services don't report intra-chunk progress, so a spinner is the honest representation
- **Two separate phases, not one combined bar**: the upload and transcription are fundamentally different operations with different progress semantics; combining them into one 0-100% bar was the original UX problem

## Deferred to Planning

- [Affects R6][Technical] How to derive per-chunk progress from the server's `progress_percent` field (which is overall progress). Likely: `chunk_progress = (progress_percent - chunk_start_pct) / chunk_width_pct * 100` where `chunk_width_pct = 100 / total_chunks`
- [Affects R8][Technical] Whether `LongAudioProgress` needs a new field to distinguish "upload phase" from "transcribing phase", or if the existing `status` enum (`.uploading` vs `.running`) is sufficient

## Next Steps

→ `/ce:plan` for structured implementation planning
