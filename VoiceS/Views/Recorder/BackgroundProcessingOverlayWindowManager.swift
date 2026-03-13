import SwiftUI
import AppKit

enum BackgroundProcessingOverlayMode: Equatable {
    case transcribing
    case enhancing

    init?(backgroundState: BackgroundTranscriptionState, isBackgroundProcessing: Bool) {
        switch backgroundState {
        case .enhancing:
            self = .enhancing
        case .transcribing:
            self = .transcribing
        case .idle:
            guard isBackgroundProcessing else { return nil }
            self = .transcribing
        }
    }

    var processingMode: ProcessingStatusDisplay.Mode {
        switch self {
        case .transcribing:
            return .transcribing
        case .enhancing:
            return .enhancing
        }
    }
}

private struct BackgroundProcessingOverlayView: View {
    let mode: BackgroundProcessingOverlayMode

    var body: some View {
        ProcessingStatusDisplay(mode: mode.processingMode, color: .white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}

@MainActor
final class BackgroundProcessingOverlayWindowManager {
    private let overlaySize = NSSize(width: 156, height: 54)
    private let bottomPadding: CGFloat = 24
    private let miniRecorderHeight: CGFloat = 60
    private let overlayGap: CGFloat = 12
    private let topPadding: CGFloat = 8
    private let notchRecordingOffset: CGFloat = 44

    private var panel: NSPanel?
    private var hostingController: NSHostingController<BackgroundProcessingOverlayView>?

    func show(
        recorderType: String,
        mode: BackgroundProcessingOverlayMode,
        isRecordingPanelVisible: Bool
    ) {
        let frame = calculateFrame(
            recorderType: recorderType,
            isRecordingPanelVisible: isRecordingPanelVisible
        )

        if panel == nil {
            let panel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar + 4
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.ignoresMouseEvents = true

            let hostingController = NSHostingController(rootView: BackgroundProcessingOverlayView(mode: mode))
            panel.contentView = hostingController.view

            self.panel = panel
            self.hostingController = hostingController
        } else {
            hostingController?.rootView = BackgroundProcessingOverlayView(mode: mode)
        }

        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        hostingController = nil
    }

    private func calculateFrame(
        recorderType: String,
        isRecordingPanelVisible: Bool
    ) -> NSRect {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - (overlaySize.width / 2)

        if recorderType == "notch" {
            var y = visibleFrame.maxY - overlaySize.height - topPadding
            if isRecordingPanelVisible {
                y -= notchRecordingOffset
            }

            return NSRect(x: x, y: y, width: overlaySize.width, height: overlaySize.height)
        }

        var y = visibleFrame.minY + bottomPadding
        if isRecordingPanelVisible {
            y += miniRecorderHeight + overlayGap
        }

        return NSRect(x: x, y: y, width: overlaySize.width, height: overlaySize.height)
    }
}
