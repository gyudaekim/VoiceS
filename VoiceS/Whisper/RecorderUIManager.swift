import Foundation
import SwiftUI
import os

@MainActor
class RecorderUIManager: ObservableObject {
    @Published var miniRecorderError: String?

    @Published var recorderType: String = UserDefaults.standard.string(forKey: "RecorderType") ?? "mini" {
        didSet {
            if oldValue == "notch" {
                notchWindowManager?.hide()
                notchWindowManager = nil
            } else {
                miniWindowManager?.hide()
                miniWindowManager = nil
            }

            Task { @MainActor in
                syncPanels()
            }
            UserDefaults.standard.set(recorderType, forKey: "RecorderType")
        }
    }

    @Published var isMiniRecorderVisible = false {
        didSet {
            Task { @MainActor in
                syncPanels()
            }
        }
    }

    var notchWindowManager: NotchWindowManager?
    var miniWindowManager: MiniWindowManager?
    var backgroundProcessingWindowManager: BackgroundProcessingOverlayWindowManager?

    private weak var engine: VoiceSEngine?
    private var recorder: Recorder?

    private let logger = Logger(subsystem: "com.gdkim.voices", category: "RecorderUIManager")

    init() {}

    /// Call after VoiceSEngine is created to break the circular init dependency.
    func configure(engine: VoiceSEngine, recorder: Recorder) {
        self.engine = engine
        self.recorder = recorder
        setupNotifications()
    }

    // MARK: - Recorder Panel Management

    func syncPanels() {
        guard let engine = engine else { return }

        if isMiniRecorderVisible {
            showRecorderPanel()
        } else {
            hideRecorderPanel()
        }

        syncBackgroundProcessingOverlay(using: engine)
    }

    func showRecorderPanel() {
        guard let engine = engine, let recorder = recorder else { return }
        logger.notice("Showing \(self.recorderType, privacy: .public) recorder")

        if recorderType == "notch" {
            if notchWindowManager == nil {
                notchWindowManager = NotchWindowManager(engine: engine, recorder: recorder)
            }
            notchWindowManager?.show()
        } else {
            if miniWindowManager == nil {
                miniWindowManager = MiniWindowManager(engine: engine, recorder: recorder)
            }
            miniWindowManager?.show()
        }
    }

    func hideRecorderPanel() {
        if recorderType == "notch" {
            notchWindowManager?.hide()
        } else {
            miniWindowManager?.hide()
        }
    }

    private func syncBackgroundProcessingOverlay(using engine: VoiceSEngine) {
        guard let mode = BackgroundProcessingOverlayMode(
            backgroundState: engine.backgroundState,
            isBackgroundProcessing: engine.isBackgroundProcessing
        ) else {
            backgroundProcessingWindowManager?.hide()
            return
        }

        if backgroundProcessingWindowManager == nil {
            backgroundProcessingWindowManager = BackgroundProcessingOverlayWindowManager()
        }

        backgroundProcessingWindowManager?.show(
            recorderType: recorderType,
            mode: mode,
            isRecordingPanelVisible: isMiniRecorderVisible
        )
    }

    // MARK: - Mini Recorder Management

    func toggleMiniRecorder(powerModeId: UUID? = nil) async {
        guard let engine = engine else { return }
        logger.notice("toggleMiniRecorder called – visible=\(self.isMiniRecorderVisible, privacy: .public), state=\(String(describing: engine.recordingState), privacy: .public)")

        if isMiniRecorderVisible {
            if engine.recordingState == .recording {
                logger.notice("toggleMiniRecorder: stopping recording (was recording)")
                await engine.toggleRecord(powerModeId: powerModeId)
            } else {
                logger.notice("toggleMiniRecorder: cancelling (was not recording)")
                await cancelRecording()
            }
        } else {
            let startResult = await engine.startRecordingIfPossible(powerModeId: powerModeId)
            guard startResult == .started else { return }
            SoundManager.shared.playStartSound()
            await MainActor.run { isMiniRecorderVisible = true }
        }
    }

    func closePanelAfterRecordingStop() async {
        await MainActor.run {
            isMiniRecorderVisible = false
        }
    }

    func dismissMiniRecorder() async {
        guard let engine = engine, let recorder = recorder else { return }
        logger.notice("dismissMiniRecorder called – state=\(String(describing: engine.recordingState), privacy: .public)")

        if engine.recordingState == .busy {
            logger.notice("dismissMiniRecorder: early return, state is busy")
            return
        }

        let wasRecording = engine.recordingState == .recording

        await MainActor.run {
            engine.recordingState = .busy
        }

        // Cancel and release any active streaming session to prevent resource leaks.
        engine.currentSession?.cancel()
        engine.currentSession = nil

        if wasRecording {
            await recorder.stopRecording()
        }

        // Clear captured context when the recorder is dismissed
        if let enhancementService = engine.enhancementService {
            await MainActor.run {
                enhancementService.clearCapturedContexts()
            }
        }

        await MainActor.run {
            isMiniRecorderVisible = false
        }

        if !engine.isBackgroundProcessing {
            await engine.cleanupResources()
        }

        if UserDefaults.standard.bool(forKey: PowerModeDefaults.autoRestoreKey) {
            await PowerModeSessionManager.shared.endSession()
            await MainActor.run {
                PowerModeManager.shared.setActiveConfiguration(nil)
            }
        }

        await MainActor.run {
            engine.recordingState = .idle
        }
        logger.notice("dismissMiniRecorder completed")
    }

    func resetOnLaunch() async {
        guard let engine = engine, let recorder = recorder else { return }
        logger.notice("Resetting recording state on launch")
        await recorder.stopRecording()
        hideRecorderPanel()
        await MainActor.run {
            isMiniRecorderVisible = false
            engine.shouldCancelRecording = false
            miniRecorderError = nil
            engine.recordingState = .idle
        }
        backgroundProcessingWindowManager?.hide()
        if !engine.isBackgroundProcessing {
            await engine.cleanupResources()
        }
    }

    func cancelRecording() async {
        guard let engine = engine else { return }
        logger.notice("cancelRecording called")
        SoundManager.shared.playEscSound()
        if engine.recordingState == .recording {
            engine.shouldCancelRecording = true
            await engine.toggleRecord()
            await closePanelAfterRecordingStop()

            if UserDefaults.standard.bool(forKey: PowerModeDefaults.autoRestoreKey) {
                await PowerModeSessionManager.shared.endSession()
                await MainActor.run {
                    PowerModeManager.shared.setActiveConfiguration(nil)
                }
            }
            return
        }

        engine.shouldCancelRecording = true
        await dismissMiniRecorder()
    }

    // MARK: - Notification Handling

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleMiniRecorder),
            name: .toggleMiniRecorder,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissMiniRecorder),
            name: .dismissMiniRecorder,
            object: nil
        )
    }

    @objc public func handleToggleMiniRecorder() {
        logger.notice("handleToggleMiniRecorder: .toggleMiniRecorder notification received")
        Task {
            await toggleMiniRecorder()
        }
    }

    @objc public func handleDismissMiniRecorder() {
        logger.notice("handleDismissMiniRecorder: .dismissMiniRecorder notification received")
        Task {
            await dismissMiniRecorder()
        }
    }
}
