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

    var licenseViewModel: LicenseViewModel

    init(
        modelContext: ModelContext,
        serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        self.modelContext = modelContext
        self.serviceRegistry = serviceRegistry
        self.enhancementService = enhancementService
        self.licenseViewModel = LicenseViewModel()
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

            if snapshot.isTextFormattingEnabled {
                text = WhisperTextFormatter.format(text)
                logger.notice("📝 Formatted transcript: \(text, privacy: .public)")
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            logger.notice("📝 WordReplacement: \(text, privacy: .public)")

            let audioAsset = AVURLAsset(url: audioURL)
            let actualDuration = (try? CMTimeGetSeconds(await audioAsset.load(.duration))) ?? 0.0

            transcription.text = text
            transcription.duration = actualDuration
            transcription.transcriptionModelName = model.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.powerModeName = snapshot.powerModeName
            transcription.powerModeEmoji = snapshot.powerModeEmoji
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
                    transcription.enhancedText = "Enhancement failed: \(error)"
                    if shouldCancel() { await onCleanup(); return }
                }
            }

            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue

        } catch {
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let recoverySuggestion = (error as? LocalizedError)?.recoverySuggestion ?? ""
            let fullErrorText = recoverySuggestion.isEmpty ? errorDescription : "\(errorDescription) \(recoverySuggestion)"

            transcription.text = "Transcription Failed: \(fullErrorText)"
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        }

        try? modelContext.save()
        NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)

        if shouldCancel() { await onCleanup(); return }

        if var textToPaste = finalPastedText,
           transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
            if case .trialExpired = licenseViewModel.licenseState {
                textToPaste = """
                    Your trial has expired. Upgrade to VoiceS Local at github.com/gdkim/VoiceS
                    \n\(textToPaste)
                    """
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                CursorPaster.pasteAtCursor(textToPaste + (snapshot.appendTrailingSpace ? " " : ""))

                if snapshot.shouldAutoSend {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        CursorPaster.pressEnter()
                    }
                }
            }
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
