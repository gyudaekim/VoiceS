import Foundation
import AVFoundation
import SwiftData
import os

/// Handles the full post-recording pipeline:
/// transcribe → filter → format → word-replace → prompt-detect → AI enhance → save → paste
@MainActor
class TranscriptionPipeline {
    private let modelContext: ModelContext
    private let serviceRegistry: TranscriptionServiceRegistry
    private let enhancementService: AIEnhancementService?
    private let promptDetectionService = PromptDetectionService()
    private let logger = Logger(subsystem: "com.gdkim.voices", category: "TranscriptionPipeline")

    init(
        modelContext: ModelContext,
        serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        self.modelContext = modelContext
        self.serviceRegistry = serviceRegistry
        self.enhancementService = enhancementService
    }

    /// Run the full pipeline for a given transcription record.
    /// - Parameters:
    ///   - transcription: The pending Transcription SwiftData object to populate and save.
    ///   - audioURL: The recorded audio file.
    ///   - model: The transcription model to use.
    ///   - session: An active streaming session if one was prepared, otherwise nil.
    ///   - snapshot: Immutable per-recording settings captured when the job was enqueued.
    ///   - onBackgroundStateChange: Called when the pipeline moves to a new background stage.
    ///   - shouldCancel: Returns true if the user requested cancellation.
    ///   - onCleanup: Called when cancellation is detected to release model resources.
    func run(
        transcription: Transcription,
        audioURL: URL,
        model: any TranscriptionModel,
        session: TranscriptionSession?,
        snapshot: TranscriptionJobSnapshot,
        onBackgroundStateChange: @escaping (BackgroundTranscriptionState) -> Void,
        shouldCancel: () -> Bool,
        onCleanup: @escaping () async -> Void
    ) async {
        if shouldCancel() {
            await onCleanup()
            return
        }

        onBackgroundStateChange(.transcribing)

        Task {
            let isSystemMuteEnabled = UserDefaults.standard.bool(forKey: "isSystemMuteEnabled")
            if isSystemMuteEnabled {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            SoundManager.shared.playStopSound()
        }

        var finalPastedText: String?
        var promptDetectionResult: PromptDetectionService.PromptDetectionResult?

        logger.notice("🔄 Starting transcription...")

        do {
            let transcriptionStart = Date()
            var text: String
            if let session {
                text = try await session.transcribe(audioURL: audioURL)
            } else {
                text = try await serviceRegistry.transcribe(audioURL: audioURL, model: model)
            }
            logger.notice("📝 Transcript: \(text, privacy: .public)")
            text = TranscriptionOutputFilter.filter(text)
            logger.notice("📝 Output filter result: \(text, privacy: .public)")
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

            if shouldCancel() { await onCleanup(); return }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Base metadata shared by both success and empty-transcript paths.
            let audioAsset = AVURLAsset(url: audioURL)
            let actualDuration = (try? CMTimeGetSeconds(await audioAsset.load(.duration))) ?? 0.0
            transcription.duration = actualDuration
            transcription.transcriptionModelName = model.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.powerModeName = snapshot.powerModeName
            transcription.powerModeEmoji = snapshot.powerModeEmoji

            if text.isEmpty {
                // Whisper can return an empty string for silent audio, very short
                // clips, or background noise. Previously this was treated as a
                // success and an empty Cmd+V was dispatched — the user saw the
                // "completed" UI with nothing pasted. Surface it as a failure.
                transcription.text = ""
                transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
                logger.notice("⚠️ Empty transcript — skipping paste")
                NotificationManager.shared.showNotification(
                    title: "No speech detected",
                    type: .warning
                )
            } else {
                if snapshot.isTextFormattingEnabled {
                    text = WhisperTextFormatter.format(text)
                    logger.notice("📝 Formatted transcript: \(text, privacy: .public)")
                }

                text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
                logger.notice("📝 WordReplacement: \(text, privacy: .public)")

                transcription.text = text
                finalPastedText = text

                if let enhancementService,
                   enhancementService.isConfigured,
                   let enhancementSnapshot = snapshot.enhancementContext {
                    let detectionResult = promptDetectionService.analyzeText(
                        text,
                        promptSnapshot: enhancementSnapshot
                    )
                    promptDetectionResult = detectionResult
                }

                if let enhancementService,
                   enhancementService.isConfigured,
                   let enhancementSnapshot = effectiveEnhancementSnapshot(
                        from: snapshot.enhancementContext,
                        detectionResult: promptDetectionResult
                   ),
                   enhancementSnapshot.isEnabled || promptDetectionResult?.shouldEnableAI == true {
                    if shouldCancel() { await onCleanup(); return }

                    onBackgroundStateChange(.enhancing)
                    let textForAI = promptDetectionResult?.processedText ?? text

                    do {
                        let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(
                            textForAI,
                            snapshot: enhancementSnapshot
                        )
                        logger.notice("📝 AI enhancement: \(enhancedText, privacy: .public)")
                        transcription.enhancedText = enhancedText
                        transcription.aiEnhancementModelName = enhancementService.getAIService()?.currentModel
                        transcription.promptName = promptName
                        transcription.enhancementDuration = enhancementDuration
                        transcription.aiRequestSystemMessage = enhancementService.lastSystemMessageSent
                        transcription.aiRequestUserMessage = enhancementService.lastUserMessageSent
                        finalPastedText = enhancedText
                    } catch {
                        logger.error("Enhancement failed: \(error.localizedDescription, privacy: .public)")
                        transcription.enhancedText = nil
                        if shouldCancel() { await onCleanup(); return }
                        // Fall back to raw transcription for paste, but tell the
                        // user why they didn't get the enhanced version.
                        NotificationManager.shared.showNotification(
                            title: "AI enhancement failed — pasted raw transcript",
                            type: .warning
                        )
                    }
                }

                transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue
            }

        } catch {
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let recoverySuggestion = (error as? LocalizedError)?.recoverySuggestion ?? ""
            let fullErrorText = recoverySuggestion.isEmpty ? errorDescription : "\(errorDescription) \(recoverySuggestion)"

            transcription.text = "Transcription Failed: \(fullErrorText)"
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            logger.error("Transcription failed: \(fullErrorText, privacy: .public)")
            NotificationManager.shared.showNotification(
                title: "Transcription failed",
                type: .error
            )
        }

        try? modelContext.save()

        if shouldCancel() { await onCleanup(); return }

        if let textToPaste = finalPastedText,
           transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
            // Small delay so the recorder panel finishes dismissing and the
            // target app has focus before we dispatch Cmd+V. Clipboard write
            // verification is now handled inside CursorPaster itself.
            try? await Task.sleep(nanoseconds: 50_000_000)

            let pasteResult = CursorPaster.pasteAtCursor(
                textToPaste + (snapshot.appendTrailingSpace ? " " : "")
            )

            if snapshot.shouldAutoSend, case .succeeded = pasteResult {
                try? await Task.sleep(nanoseconds: 200_000_000)
                CursorPaster.pressEnter()
            }

            surfacePasteFailure(pasteResult)
        }

        NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)

    }

    private func surfacePasteFailure(_ result: PasteResult) {
        switch result {
        case .succeeded:
            return
        case .clipboardWriteFailed:
            NotificationManager.shared.showNotification(
                title: "Paste failed — could not write transcript to clipboard",
                type: .error
            )
        case .accessibilityDenied:
            NotificationManager.shared.showNotification(
                title: "Accessibility permission required for VoiceS to paste",
                type: .error,
                duration: 5.0
            )
        case .inputSourceUnavailable:
            NotificationManager.shared.showNotification(
                title: "Paste failed — keyboard input source unavailable",
                type: .error
            )
        case .appleScriptFailed(let message):
            NotificationManager.shared.showNotification(
                title: "AppleScript paste failed: \(message)",
                type: .error
            )
        }
    }

    private func effectiveEnhancementSnapshot(
        from snapshot: EnhancementContextSnapshot?,
        detectionResult: PromptDetectionService.PromptDetectionResult?
    ) -> EnhancementContextSnapshot? {
        guard let snapshot else { return nil }

        let shouldEnableAI = snapshot.isEnabled || (detectionResult?.shouldEnableAI == true)
        let selectedPromptId = detectionResult?.selectedPromptId ?? snapshot.selectedPromptId

        return EnhancementContextSnapshot(
            isEnabled: shouldEnableAI,
            selectedPromptId: selectedPromptId,
            prompts: snapshot.prompts,
            useClipboardContext: snapshot.useClipboardContext,
            useScreenCaptureContext: snapshot.useScreenCaptureContext,
            capturedClipboardText: snapshot.capturedClipboardText,
            capturedScreenText: snapshot.capturedScreenText
        )
    }
}
