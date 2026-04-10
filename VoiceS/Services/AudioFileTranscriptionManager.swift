import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import os

@MainActor
class AudioTranscriptionManager: ObservableObject {
    static let shared = AudioTranscriptionManager()

    @Published var isProcessing = false
    @Published var processingPhase: ProcessingPhase = .idle
    @Published var currentTranscription: Transcription?
    @Published var currentTranscriptionMarkdown: String?
    @Published var longAudioProgress: LongAudioProgress = .idle
    @Published var errorMessage: String?

    private var currentTask: Task<Void, Error>?
    private let audioProcessor = AudioProcessor()
    private let logger = Logger(subsystem: "com.gdkim.voices", category: "AudioTranscriptionManager")

    enum ProcessingPhase {
        case idle
        case loading
        case processingAudio
        case transcribing
        case enhancing
        case completed

        var message: String {
            switch self {
            case .idle:
                return ""
            case .loading:
                return "Loading transcription model..."
            case .processingAudio:
                return "Processing audio file for transcription..."
            case .transcribing:
                return "Transcribing audio..."
            case .enhancing:
                return "Enhancing transcription with AI..."
            case .completed:
                return "Transcription completed!"
            }
        }
    }

    private init() {}

    func startProcessing(
        url: URL,
        modelContext: ModelContext,
        engine: VoiceSEngine,
        languageHint: String = "auto"
    ) {
        // Cancel any existing processing
        cancelProcessing()

        isProcessing = true
        processingPhase = .loading
        longAudioProgress = .idle
        currentTranscriptionMarkdown = nil
        errorMessage = nil

        currentTask = Task {
            // Re-acquire security-scoped access for the file URL — the original scope
            // from validateAndSetAudioFile was released in its defer block before this Task runs.
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                guard let currentModel = engine.transcriptionModelManager.currentTranscriptionModel else {
                    throw TranscriptionError.noModelSelected
                }

                let serviceRegistry = TranscriptionServiceRegistry(
                    modelProvider: engine.whisperModelManager,
                    modelsDirectory: engine.whisperModelManager.modelsDirectory,
                    modelContext: modelContext
                )
                defer {
                    serviceRegistry.cleanup()
                }

                processingPhase = .processingAudio

                let audioAsset = AVURLAsset(url: url)
                let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))

                // Decide strategy early so we know whether to keep the original file as-is
                // (server path) or pre-convert to 16 kHz mono WAV (client chunking path).
                //
                // First check if the current model is a CustomCloudModel. If not (e.g., a
                // predefined QwenModel won the name-collision in allAvailableModels), scan
                // CustomModelManager for any registered model whose endpoint matches the
                // async job pattern. This lets the server path activate even when the user
                // selects the predefined local model name.
                let serverCustomModel: CustomCloudModel?
                let serverBaseURL: URL?
                if let custom = currentModel as? CustomCloudModel,
                   let base = QwenServerJobStrategy.deriveBaseURL(from: custom.apiEndpoint) {
                    serverCustomModel = custom
                    serverBaseURL = base
                    logger.info("Derived server base URL: \(base.absoluteString, privacy: .public) from selected CustomCloudModel endpoint: \(custom.apiEndpoint, privacy: .public)")
                } else if let fallbackCustom = CustomModelManager.shared.customModels.first(where: {
                    QwenServerJobStrategy.deriveBaseURL(from: $0.apiEndpoint) != nil
                }) {
                    serverCustomModel = fallbackCustom
                    serverBaseURL = QwenServerJobStrategy.deriveBaseURL(from: fallbackCustom.apiEndpoint)
                    logger.info("Selected model \(currentModel.displayName, privacy: .public) is not a CustomCloudModel, but found server-compatible CustomCloudModel '\(fallbackCustom.displayName, privacy: .public)' at \(fallbackCustom.apiEndpoint, privacy: .public)")
                } else {
                    serverCustomModel = nil
                    serverBaseURL = nil
                    logger.info("No server-compatible CustomCloudModel found — will use client chunking for \(currentModel.displayName, privacy: .public)")
                }

                // Prepare permanent audio file for SwiftData Transcription.audioFileURL
                let recordingsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("com.gdkim.VoiceS")
                    .appendingPathComponent("Recordings")
                try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)

                let permanentURL: URL
                if serverBaseURL != nil {
                    // Copy original file verbatim — uploading an MP3/M4A is far smaller than a 16 kHz WAV,
                    // and the server re-normalizes via ffmpeg anyway.
                    let ext = url.pathExtension.isEmpty ? "wav" : url.pathExtension
                    permanentURL = recordingsDirectory
                        .appendingPathComponent("transcribed_\(UUID().uuidString).\(ext)")
                    try FileManager.default.copyItem(at: url, to: permanentURL)
                } else {
                    // Client chunking: convert once up front (matches legacy behavior). This keeps the
                    // chunking strategy's later `processAudioToSamples` cheap since the file is already
                    // 16 kHz mono PCM.
                    let samples = try await audioProcessor.processAudioToSamples(url)
                    permanentURL = recordingsDirectory
                        .appendingPathComponent("transcribed_\(UUID().uuidString).wav")
                    try audioProcessor.saveSamplesAsWav(samples: samples, to: permanentURL)
                }

                try Task.checkCancellation()

                // Build the strategy
                let strategy: LongAudioTranscriptionStrategy
                if let baseURL = serverBaseURL, let custom = serverCustomModel {
                    strategy = QwenServerJobStrategy(baseURL: baseURL, apiKey: custom.apiKey)
                    logger.info("Using QwenServerJobStrategy @ \(baseURL.absoluteString, privacy: .public)")
                } else {
                    strategy = ClientChunkingStrategy(
                        serviceRegistry: serviceRegistry,
                        model: currentModel,
                        audioProcessor: audioProcessor
                    )
                    logger.info("Using ClientChunkingStrategy for \(currentModel.displayName, privacy: .public)")
                }

                processingPhase = .transcribing
                let transcriptionStart = Date()

                let progressCallback: (LongAudioProgress) -> Void = { [weak self] progress in
                    self?.longAudioProgress = progress
                }

                let result: LongAudioResult
                do {
                    result = try await strategy.transcribe(
                        audioURL: permanentURL,
                        languageHint: languageHint,
                        progress: progressCallback
                    )
                } catch LongAudioTranscriptionError.asyncJobsNotSupported {
                    // Server doesn't support the async job API (e.g., it's a generic
                    // OpenAI-compatible endpoint, not the gdk-server Qwen ASR). Fall back
                    // to client-side chunking.
                    logger.info("Server doesn't support async jobs — falling back to client chunking")
                    let fallbackStrategy = ClientChunkingStrategy(
                        serviceRegistry: serviceRegistry,
                        model: currentModel,
                        audioProcessor: audioProcessor
                    )
                    result = try await fallbackStrategy.transcribe(
                        audioURL: permanentURL,
                        languageHint: languageHint,
                        progress: progressCallback
                    )
                } catch is CancellationError {
                    throw TranscriptionError.transcriptionCancelled
                }

                let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

                var text = TranscriptionOutputFilter.filter(result.text)
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)

                let powerModeManager = PowerModeManager.shared
                let activePowerModeConfig = powerModeManager.currentActiveConfiguration
                let powerModeName = (activePowerModeConfig?.isEnabled == true) ? activePowerModeConfig?.name : nil
                let powerModeEmoji = (activePowerModeConfig?.isEnabled == true) ? activePowerModeConfig?.emoji : nil

                if UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled") {
                    text = WhisperTextFormatter.format(text)
                }

                text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)

                // Cache the Markdown for the download button while the result is on screen.
                currentTranscriptionMarkdown = result.markdown

                // Handle enhancement if enabled
                if let enhancementService = engine.enhancementService,
                   enhancementService.isEnhancementEnabled,
                   enhancementService.isConfigured {
                    processingPhase = .enhancing
                    do {
                        let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(text)
                        let transcription = Transcription(
                            text: text,
                            duration: duration,
                            enhancedText: enhancedText,
                            audioFileURL: permanentURL.absoluteString,
                            transcriptionModelName: currentModel.displayName,
                            aiEnhancementModelName: enhancementService.getAIService()?.currentModel,
                            promptName: promptName,
                            transcriptionDuration: transcriptionDuration,
                            enhancementDuration: enhancementDuration,
                            aiRequestSystemMessage: enhancementService.lastSystemMessageSent,
                            aiRequestUserMessage: enhancementService.lastUserMessageSent,
                            powerModeName: powerModeName,
                            powerModeEmoji: powerModeEmoji,
                            source: "file",
                            originalFileName: url.lastPathComponent,
                            transcriptionStatus: .completed
                        )
                        modelContext.insert(transcription)
                        try modelContext.save()
                        NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
                        NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
                        currentTranscription = transcription
                    } catch {
                        logger.error("❌ Enhancement failed: \(error.localizedDescription, privacy: .public)")
                        let transcription = Transcription(
                            text: text,
                            duration: duration,
                            audioFileURL: permanentURL.absoluteString,
                            transcriptionModelName: currentModel.displayName,
                            promptName: nil,
                            transcriptionDuration: transcriptionDuration,
                            powerModeName: powerModeName,
                            powerModeEmoji: powerModeEmoji,
                            source: "file",
                            originalFileName: url.lastPathComponent,
                            transcriptionStatus: .completed
                        )
                        modelContext.insert(transcription)
                        try modelContext.save()
                        NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
                        NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
                        currentTranscription = transcription
                    }
                } else {
                    let transcription = Transcription(
                        text: text,
                        duration: duration,
                        audioFileURL: permanentURL.absoluteString,
                        transcriptionModelName: currentModel.displayName,
                        promptName: nil,
                        transcriptionDuration: transcriptionDuration,
                        powerModeName: powerModeName,
                        powerModeEmoji: powerModeEmoji,
                        source: "file",
                        originalFileName: url.lastPathComponent,
                        transcriptionStatus: .completed
                    )
                    modelContext.insert(transcription)
                    try modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
                    NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
                    currentTranscription = transcription
                }

                processingPhase = .completed
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await finishProcessing()

            } catch {
                await handleError(error)
            }
        }
    }

    func cancelProcessing() {
        currentTask?.cancel()
    }

    private func finishProcessing() {
        isProcessing = false
        processingPhase = .idle
        longAudioProgress = .idle
        currentTask = nil
    }

    private func handleError(_ error: Error) {
        if error is CancellationError || (error as? TranscriptionError) == .transcriptionCancelled {
            logger.info("Transcription cancelled")
        } else {
            logger.error("❌ Transcription error: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
        isProcessing = false
        processingPhase = .idle
        longAudioProgress = .idle
        currentTranscriptionMarkdown = nil
        currentTask = nil
    }
}

enum TranscriptionError: Error, LocalizedError, Equatable {
    case noModelSelected
    case transcriptionCancelled

    var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return "No transcription model selected"
        case .transcriptionCancelled:
            return "Transcription was cancelled"
        }
    }
}
