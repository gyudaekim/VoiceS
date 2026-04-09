import SwiftUI
import AppKit

struct ClipboardManager {
    enum ClipboardError: Error {
        case copyFailed
        case accessDenied
    }

    @discardableResult
    static func setClipboard(_ text: String, transient: Bool = false) -> Bool {
        let pasteboard = NSPasteboard.general
        let beforeChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        let didWriteString = pasteboard.setString(text, forType: .string)

        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            pasteboard.setString(bundleIdentifier, forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
        }

        if transient {
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }

        // The pasteboard server bumps changeCount on every successful write.
        // If it did not move, the write did not land in the system pasteboard
        // and a follow-up Cmd+V would paste whatever was there before.
        let didBumpChangeCount = pasteboard.changeCount > beforeChangeCount
        guard didWriteString && didBumpChangeCount else {
            return false
        }

        // Verify the string we just wrote is actually readable back.
        // This catches cases where another app is holding/racing the pasteboard.
        if pasteboard.string(forType: .string) != text {
            return false
        }

        return true
    }

    @discardableResult
    static func copyToClipboard(_ text: String) -> Bool {
        return setClipboard(text, transient: false)
    }

    static func getClipboardContent() -> String? {
        return NSPasteboard.general.string(forType: .string)
    }
}

struct ClipboardMessageModifier: ViewModifier {
    @Binding var message: String
    
    func body(content: Content) -> some View {
        content
            .overlay(
                Group {
                    if !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(4)
                            .transition(.opacity)
                            .animation(.easeInOut, value: message)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding()
            )
    }
}

extension View {
    func clipboardMessage(_ message: Binding<String>) -> some View {
        self.modifier(ClipboardMessageModifier(message: message))
    }
}
