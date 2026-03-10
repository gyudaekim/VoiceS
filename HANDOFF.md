# VoiceS Handoff

## Goal
Continue the `VoiceInk` -> `VoiceS` personal-fork rebrand and finish the cleanup so the project is a coherent local-only fork.

This file is intended to be sufficient context for the next agent. Load this file first, then work from here.

## Repo State
- Repo path: `/Users/gdkim/Projects/VoiceS`
- Original upstream path was cloned as `VoiceS`, then internal project/app names were renamed from `VoiceInk` to `VoiceS`
- Current collaboration state: implementation has already started and builds successfully
- Current git branch: `main`
- There is a large rename diff because the old `VoiceInk/...` tree became `VoiceS/...`

## What Was Already Done

### Project / target rename
- Renamed:
  - `VoiceInk.xcodeproj` -> `VoiceS.xcodeproj`
  - `VoiceInk` source folder -> `VoiceS`
  - `VoiceInkTests` -> `VoiceSTests`
  - `VoiceInkUITests` -> `VoiceSUITests`
  - main scheme -> `VoiceS`
  - app product -> `VoiceS.app`
- Main app entry point is now `VoiceS/VoiceS.swift`
- Engine files were renamed to `VoiceSEngine*`
- CSV export service file was renamed to `VoiceSCSVExportService.swift`

### Identity / local-only updates
- Build scripts updated to target `VoiceS.xcodeproj` and scheme `VoiceS`
- `make local` now produces `~/Downloads/VoiceS.app`
- Bundle IDs updated to:
  - app: `com.gdkim.VoiceS`
  - tests: `com.gdkim.VoiceSTests`
  - UI tests: `com.gdkim.VoiceSUITests`
- App support / persistence namespace was moved to `com.gdkim.VoiceS`
- UserDefaults / local app keys were renamed from `VoiceInk...` to `VoiceS...`
- `VoiceS.local.entitlements` is wired into local builds

### Update / announcement / iCloud adjustments
- `Info.plist` Sparkle keys were removed
- `VoiceS.swift` no longer calls auto-update or announcements on launch
- `UpdaterViewModel` was stubbed to no-op
- `AnnouncementsService` was stubbed to no-op
- `SettingsView` no longer shows auto-update or announcements toggles
- `MenuBarView` no longer shows "Check for Updates"
- `VoiceS.entitlements` had CloudKit and keychain access-group entries removed
- `VoiceS.swift` dictionary SwiftData config now uses `cloudKitDatabase: .none`

### Support / branding updates
- User-facing `VoiceInk` strings were bulk-replaced with `VoiceS`
- `EmailSupport.openSupportEmail()` now opens the GitHub project page instead of composing upstream support email
- Docs and scripts were partially updated to `VoiceS`

## What Was Verified

### Successful checks
- `xcodebuild -list -project VoiceS.xcodeproj` succeeded
- `make local` succeeded
- Resulting app exists at:
  - `~/Downloads/VoiceS.app`

### Important build notes
- The first successful `make local` also built `whisper.cpp` XCFramework in:
  - `~/VoiceS-Dependencies/whisper.cpp/build-apple/whisper.xcframework`
- Build completed with warnings but no blocking errors

### Known warning from build
- Xcode warning:
  - `The Copy Bundle Resources build phase contains this target's Info.plist file`
- This did not block build, but should be cleaned up in `VoiceS.xcodeproj/project.pbxproj`

## What Still Needs To Be Done

### 1. Finish local-only cleanup in the Xcode project
The app builds, but project references still include upstream update/cloud artifacts.

Still present in `VoiceS.xcodeproj/project.pbxproj`:
- `Sparkle` package reference and framework linkage
- `CloudKit.framework` reference

Recommended next steps:
- Remove `Sparkle` framework/product reference from the app target
- Remove `Sparkle` package reference from the project if nothing still imports it
- Remove `CloudKit.framework` linkage from the app target
- Re-run `xcodebuild -list -project VoiceS.xcodeproj`
- Re-run `make local`

Notes:
- The app currently still resolves the Sparkle package during build because the project file still references it
- Runtime update behavior is already stubbed off, so this is cleanup rather than a current blocker

### 2. Remove leftover commercial/license UI
The project is still functionally carrying upstream license UX even though `LOCAL_BUILD` bypasses licensing.

Still present:
- `VoiceS/Models/LicenseViewModel.swift`
- `VoiceS/Views/LicenseManagementView.swift`
- `VoiceS/Views/LicenseView.swift`
- `VoiceS/Views/MetricsView.swift`
- `VoiceS/Views/Metrics/DashboardPromotionsSection.swift`
- `VoiceS/Views/Metrics/MetricsContent.swift`
- `VoiceS/Views/ContentView.swift` still has `case license = "VoiceS Local"`
- `VoiceS/Whisper/TranscriptionPipeline.swift` still prepends a trial-expired upgrade message
- `VoiceS/Whisper/VoiceSEngine.swift` still injects `LicenseViewModel`

Observed leftover strings from search:
- `VoiceS Local`
- `Upgrade to Pro`
- `Upgrade to VoiceS Local`
- promotion copy in `DashboardPromotionsSection`

Recommended next steps:
- Remove the dedicated license tab from `ContentView`
- Remove trial/pro upgrade messaging from metrics and dashboard
- Remove `trialExpired` insertion in `TranscriptionPipeline`
- Simplify `LicenseViewModel` to always licensed or remove it entirely
- If removing entirely, update `VoiceSEngine` and `TranscriptionPipeline` wiring

### 3. Clean up docs and repo metadata
Docs were bulk replaced, but they are not yet coherent.

Current issues seen in `README.md`:
- Still says "purchasing a license"
- Still mentions "automatic updates"
- Still mentions "priority support"
- Still has Homebrew command `brew install --cask voiceink`
- Still links YouTube upstream
- Still mentions Sparkle in acknowledgments
- Tone is still that of upstream commercial app, not a personal local-only fork

Recommended next steps:
- Rewrite `README.md` as a personal local fork
- Rewrite `BUILDING.md` to only describe `VoiceS`
- Decide whether `CONTRIBUTING.md` should stay upstream-like or be simplified for a personal fork
- Remove or rewrite `announcements.json` and `appcast.xml`
  - they are now effectively unused after stubbing
  - either delete them from the product model or clearly mark them as inactive

### 4. Optional but worthwhile: remove unused no-op update infrastructure
Currently:
- `UpdaterViewModel` still exists in `VoiceS.swift`
- `CheckForUpdatesView` exists but returns `EmptyView()`
- environment injection still includes `updaterViewModel`

This is harmless, but dead code.

Recommended next steps:
- Remove `UpdaterViewModel` entirely
- Remove related `.environmentObject(updaterViewModel)` injections
- Remove the command group that inserts `CheckForUpdatesView`
- Remove any remaining references in settings/menu views

### 5. Optional cleanup: logger / identifier polish
These were largely bulk-rewritten, but should be spot-checked.

Things to validate:
- logger subsystems now use `com.gdkim.voices`
- NSWindow identifiers and queue labels are coherent
- no remaining upstream namespace strings in runtime identifiers

Current search already showed no remaining raw `VoiceInk` strings in tracked files, but naming consistency still deserves a quick pass.

## Commands That Were Run

### Inspection
- `xcodebuild -list -project VoiceS.xcodeproj`
- `rg` searches for:
  - `VoiceInk`
  - `Sparkle`
  - `CloudKit`
  - `VoiceS Local`
  - `LicenseViewModel`
  - `Check for Updates`

### Build verification
- `make local`

This worked and produced `~/Downloads/VoiceS.app`.

## What Worked
- Bulk project rename from `VoiceInk` to `VoiceS`
- Xcode project and shared scheme rename
- Local build path rewrite
- Bundle identifier rewrite
- Local app build verification
- Disabling runtime use of updates and announcements
- Removing CloudKit entitlements without breaking local build

## What Didn’t Work Cleanly
- A blind bulk text replacement was useful for speed, but it left semantically wrong copy in docs and licensing UI
- Sparkle and CloudKit were neutralized functionally, but not fully removed from the Xcode project graph
- The project still contains dead code related to licensing and updates
- One Xcode warning remains about `Info.plist` being included in Copy Bundle Resources

## Suggested Finish Order
1. Remove Sparkle and CloudKit references from `VoiceS.xcodeproj/project.pbxproj`
2. Fix the `Info.plist in Copy Bundle Resources` warning
3. Remove license/pro UI and trial logic
4. Simplify dead update infrastructure
5. Rewrite `README.md` and `BUILDING.md` for a personal local-only fork
6. Re-run:
   - `xcodebuild -list -project VoiceS.xcodeproj`
   - `make local`
7. Verify `~/Downloads/VoiceS.app` still launches

## Key Files To Check First
- `/Users/gdkim/Projects/VoiceS/VoiceS.xcodeproj/project.pbxproj`
- `/Users/gdkim/Projects/VoiceS/VoiceS/VoiceS.swift`
- `/Users/gdkim/Projects/VoiceS/VoiceS/Views/ContentView.swift`
- `/Users/gdkim/Projects/VoiceS/README.md`

## Current Bottom Line
The rename is already far enough that the app builds and produces `VoiceS.app`. The remaining work is cleanup and product-shape consistency, not rescue work.
