import Foundation
import AppKit
import Carbon
import os

private let logger = Logger(subsystem: "com.VoiceS", category: "CursorPaster")

enum PasteResult {
    case succeeded
    case clipboardWriteFailed
    case accessibilityDenied
    case inputSourceUnavailable
    case appleScriptFailed(String)
}

class CursorPaster {

    // Minimum delay before restoring the user's prior clipboard contents.
    // The target app needs enough time to receive Cmd+V AND actually read the
    // pasteboard. Electron / web-based apps (Notion, Slack, VS Code, Discord)
    // and slow web text fields routinely take more than 300-500ms, so 250ms
    // was far too aggressive and caused "previous clipboard gets pasted" bug.
    private static let minimumRestoreDelay: TimeInterval = 1.2

    // Tracks the most recent in-flight clipboard restoration work so a
    // subsequent paste can flush/cancel it before starting its own cycle.
    private static var pendingRestoreWorkItem: DispatchWorkItem?

    @discardableResult
    static func pasteAtCursor(_ text: String) -> PasteResult {
        let pasteboard = NSPasteboard.general
        let shouldRestoreClipboard = UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste")

        // If a previous paste still has a pending restore scheduled, run it
        // synchronously now so we don't save "the previous transcript" as the
        // "original clipboard" of this paste.
        if let pending = pendingRestoreWorkItem {
            pending.cancel()
            pending.perform()
            pendingRestoreWorkItem = nil
        }

        var savedContents: [(NSPasteboard.PasteboardType, Data)] = []

        if shouldRestoreClipboard {
            let currentItems = pasteboard.pasteboardItems ?? []

            for item in currentItems {
                for type in item.types {
                    if let data = item.data(forType: type) {
                        savedContents.append((type, data))
                    }
                }
            }
        }

        // Verify the clipboard write actually committed before we synthesize
        // Cmd+V. Without this, a silent setString failure causes whatever was
        // in the clipboard before (the user's previously copied item) to be
        // pasted instead of the transcription.
        let writeSucceeded = ClipboardManager.setClipboard(text, transient: shouldRestoreClipboard)
        if !writeSucceeded {
            logger.error("Failed to write transcription to clipboard — skipping paste to avoid pasting stale clipboard contents")
            return .clipboardWriteFailed
        }

        let useAppleScript = UserDefaults.standard.bool(forKey: "useAppleScriptPaste")
        let pasteResult: PasteResult
        if useAppleScript {
            pasteResult = pasteUsingAppleScript()
        } else {
            pasteResult = pasteFromClipboard()
        }

        // Only schedule restoration if we actually dispatched a paste, and
        // give the target app plenty of time to consume the pasteboard.
        if shouldRestoreClipboard, case .succeeded = pasteResult, !savedContents.isEmpty {
            let userPref = UserDefaults.standard.double(forKey: "clipboardRestoreDelay")
            let delay = max(userPref, minimumRestoreDelay)

            let workItem = DispatchWorkItem {
                pasteboard.clearContents()
                for (type, data) in savedContents {
                    pasteboard.setData(data, forType: type)
                }
                pendingRestoreWorkItem = nil
            }
            pendingRestoreWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        return pasteResult
    }

    // MARK: - AppleScript paste

    // Pre-compiled AppleScript for pasting. Compiled once on first use to avoid per-paste overhead.
    private static let pasteScript: NSAppleScript? = {
        let script = NSAppleScript(source: """
            tell application "System Events"
                keystroke "v" using command down
            end tell
            """)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }()

    // Paste via AppleScript. Works with custom keyboard layouts (e.g. Neo2) where CGEvent-based paste fails.
    private static func pasteUsingAppleScript() -> PasteResult {
        var error: NSDictionary?
        pasteScript?.executeAndReturnError(&error)
        if let error = error {
            logger.error("AppleScript paste failed: \(error, privacy: .public)")
            let message = (error["NSAppleScriptErrorMessage"] as? String) ?? "Unknown AppleScript error"
            return .appleScriptFailed(message)
        }
        return .succeeded
    }

    // MARK: - CGEvent paste

    // Paste via CGEvent, temporarily switching to a QWERTY input source so virtual key 0x09 maps to "V".
    private static func pasteFromClipboard() -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility not trusted — cannot paste")
            return .accessibilityDenied
        }

        guard let currentSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            logger.error("TISCopyCurrentKeyboardInputSource returned nil")
            return .inputSourceUnavailable
        }
        let currentID = sourceID(for: currentSource) ?? "unknown"
        let switched = switchToQWERTYInputSource()
        logger.notice("Pasting: inputSource=\(currentID, privacy: .public), switched=\(switched)")

        // If we switched input sources, wait 30 ms for the system to apply it
        // before posting the CGEvents.
        let eventDelay: TimeInterval = switched ? 0.03 : 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + eventDelay) {
            let source = CGEventSource(stateID: .privateState)

            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
            let vDown   = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            let vUp     = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            let cmdUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

            cmdDown?.flags = .maskCommand
            vDown?.flags   = .maskCommand
            vUp?.flags     = .maskCommand

            cmdDown?.post(tap: .cghidEventTap)
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)
            cmdUp?.post(tap: .cghidEventTap)

            logger.notice("CGEvents posted for Cmd+V")

            if switched {
                // Restore the original input source after a short delay so the
                // posted events are processed under ABC/US first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    TISSelectInputSource(currentSource)
                    logger.notice("Restored input source to \(currentID, privacy: .public)")
                }
            }
        }

        // We consider the paste dispatched successfully once we have scheduled
        // the Cmd+V CGEvents. Actual delivery to the target app is async and
        // can't be observed from here, but we've cleared the synchronous
        // failure modes (accessibility, input source lookup).
        return .succeeded
    }

    // Try to switch to ABC or US QWERTY. Returns true if the switch was made.
    private static func switchToQWERTYInputSource() -> Bool {
        guard let currentSourceRef = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        if let currentID = sourceID(for: currentSourceRef), isQWERTY(currentID) {
            return false // already QWERTY, nothing to do
        }

        let criteria = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary
        guard let list = TISCreateInputSourceList(criteria, false)?.takeRetainedValue() as? [TISInputSource] else {
            logger.error("Failed to list input sources")
            return false
        }

        // Prefer ABC, then US.
        let preferred = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        for targetID in preferred {
            if let match = list.first(where: { sourceID(for: $0) == targetID }) {
                let status = TISSelectInputSource(match)
                if status == noErr {
                    logger.notice("Switched input source to \(targetID, privacy: .public)")
                    return true
                } else {
                    logger.error("TISSelectInputSource failed with status \(status, privacy: .public)")
                }
            }
        }

        logger.error("No QWERTY input source found to switch to")
        return false
    }

    private static func sourceID(for source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func isQWERTY(_ id: String) -> Bool {
        let qwertyIDs: Set<String> = [
            "com.apple.keylayout.ABC",
            "com.apple.keylayout.US",
            "com.apple.keylayout.USInternational-PC",
            "com.apple.keylayout.British",
            "com.apple.keylayout.Australian",
            "com.apple.keylayout.Canadian",
        ]
        return qwertyIDs.contains(id)
    }

    // MARK: - Enter key

    // Simulate pressing the Return/Enter key.
    static func pressEnter() {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .privateState)
        let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let enterUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
        enterDown?.post(tap: .cghidEventTap)
        enterUp?.post(tap: .cghidEventTap)
    }
}
