import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import os

struct FileTranscriptionJob {
    let id: UUID
    let permanentURL: URL
    let transcription: Transcription
    let languageHint: String
    let isEnhancementEnabled: Bool
    let selectedPromptId: UUID?
}

@MainActor
class AudioTranscriptionManager: ObservableObject {
    static let shared = AudioTranscriptionManager()

    @Published var isProcessing = false
    @Published var processingPhase: ProcessingPhase = .idle
    @Published var longAudioProgress: LongAudioProgress = .idle
    @Published var errorMessage: String?
    @Published var queue: [FileTranscriptionJob] = []
    @Published var currentJob: FileTranscriptionJob?

    private var currentTask: Task<Void, Error>?
    private var isProcessingQueue = false
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
                return "Processing audio file..."
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

    // MARK: - Public API

    func enqueueFiles(
        urls: [URL],
        modelContext: ModelContext,
        engine: VoiceSEngine,
        languageHint: String = "auto",
        isEnhancementEnabled: Bool = false,
        selectedPromptId: UUID? = nil
    ) {
        let recordingsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.gdkim.VoiceS")
            .appendingPathComponent("Recordings")
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)

        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let originalFileName = url.lastPathComponent

            // Copy file to permanent location
            let ext = url.pathExtension.isEmpty ? "wav" : url.pathExtension
            let permanentURL = recordingsDirectory
                .appendingPathComponent("transcribed_\(UUID().uuidString).\(ext)")
            do {
                try FileManager.default.copyItem(at: url, to: permanentURL)
            } catch {
                logger.error("Failed to copy file \(originalFileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }

            // Get duration
            let duration: TimeInterval
            if let d = try? AVURLAsset(url: permanentURL).duration {
                duration = CMTimeGetSeconds(d)
            } else {
                duration = 0
            }

            // Create Transcription record immediately
            let transcription = Transcription(
                text: "",
                duration: duration,
                audioFileURL: permanentURL.absoluteString,
                source: "file",
                originalFileName: originalFileName,
                transcriptionStatus: .queued
            )
            modelContext.insert(transcription)

            let job = FileTranscriptionJob(
                id: UUID(),
                permanentURL: permanentURL,
                transcription: transcription,
                languageHint: languageHint,
                isEnhancementEnabled: isEnhancementEnabled,
                selectedPromptId: selectedPromptId
            )
            queue.append(job)
        }

        do { try modelContext.save() } catch {
            logger.error("Failed to save queued transcriptions: \(error.localizedDescription, privacy: .public)")
        }

        if !isProcessingQueue {
            processQueue(modelContext: modelContext, engine: engine)
        }
    }

    /// Backward-compatible single-file entry point.
    func startProcessing(
        url: URL,
        modelContext: ModelContext,
        engine: VoiceSEngine,
        languageHint: String = "auto",
        isEnhancementEnabled: Bool = false,
        selectedPromptId: UUID? = nil
    ) {
        enqueueFiles(
            urls: [url],
            modelContext: modelContext,
            engine: engine,
            languageHint: languageHint,
            isEnhancementEnabled: isEnhancementEnabled,
            selectedPromptId: selectedPromptId
        )
    }

    func cancelProcessing() {
        currentTask?.cancel()
        currentTask = nil

        // Mark all queued items as failed
        for job in queue {
            job.transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        }
        queue.removeAll()
        currentJob = nil
        isProcessingQueue = false
        isProcessing = false
        processingPhase = .idle
        longAudioProgress = .idle
        errorMessage = nil
    }

    /// Mark stale queued/in-progress file transcriptions as failed (e.g., after app crash).
    func cleanupStaleJobs(modelContext: ModelContext) {
        let queuedRaw = TranscriptionStatus.queued.rawValue
        let inProgressRaw = TranscriptionStatus.inProgress.rawValue
        var descriptor = FetchDescriptor<Transcription>(
            predicate: #Predicate<Transcription> { t in
                t.source == "file" &&
                (t.transcriptionStatus == queuedRaw || t.transcriptionStatus == inProgressRaw)
            }
        )
        descriptor.fetchLimit = 100
        guard let stale = try? modelContext.fetch(descriptor) else { return }
        for t in stale {
            t.transcriptionStatus = TranscriptionStatus.failed.rawValue
        }
        try? modelContext.save()
        if !stale.isEmpty {
            logger.info("Marked \(stale.count) stale file transcription(s) as failed")
        }
    }

    // MARK: - Queue Processing

    private func processQueue(modelContext: ModelContext, engine: VoiceSEngine) {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        isProcessing = true
        errorMessage = nil

        currentTask = Task {
            while !queue.isEmpty {
                let job = queue.removeFirst()
                currentJob = job

                job.transcription.transcriptionStatus = TranscriptionStatus.inProgress.rawValue
                try? modelContext.save()

                processingPhase = .loading
                longAudioProgress = .idle

                await processJob(job, modelContext: modelContext, engine: engine)

                currentJob = nil
            }

            isProcessingQueue = false
            isProcessing = false
            processingPhase = .idle
            longAudioProgress = .idle
            currentTask = nil
        }
    }

    private func processJob(
        _ job: FileTranscriptionJob,
        modelContext: ModelContext,
        engine: VoiceSEngine
    ) async {
        let transcription = job.transcription
        let permanentURL = job.permanentURL

        do {
            guard let currentModel = engine.transcriptionModelManager.currentTranscriptionModel else {
                throw TranscriptionError.noModelSelected
            }

            let serviceRegistry = TranscriptionServiceRegistry(
                modelProvider: engine.whisperModelManager,
                modelsDirectory: engine.whisperModelManager.modelsDirectory,
                modelContext: modelContext
            )
            defer { serviceRegistry.cleanup() }

            processingPhase = .processingAudio

            // Determine strategy
            let serverCustomModel: CustomCloudModel?
            let serverBaseURL: URL?
            if let custom = currentModel as? CustomCloudModel,
               let base = QwenServerJobStrategy.deriveBaseURL(from: custom.apiEndpoint) {
                serverCustomModel = custom
                serverBaseURL = base
            } else if let fallbackCustom = CustomModelManager.shared.customModels.first(where: {
                QwenServerJobStrategy.deriveBaseURL(from: $0.apiEndpoint) != nil
            }) {
                serverCustomModel = fallbackCustom
                serverBaseURL = QwenServerJobStrategy.deriveBaseURL(from: fallbackCustom.apiEndpoint)
            } else {
                serverCustomModel = nil
                serverBaseURL = nil
            }

            // For client chunking, we may need to convert to WAV.
            // The file was copied as-is during enqueue. Convert now if needed.
            let audioURL: URL
            if serverBaseURL != nil {
                audioURL = permanentURL
            } else {
                let samples = try await audioProcessor.processAudioToSamples(permanentURL)
                let wavURL = permanentURL.deletingPathExtension().appendingPathExtension("wav")
                if wavURL != permanentURL {
                    try audioProcessor.saveSamplesAsWav(samples: samples, to: wavURL)
                    audioURL = wavURL
                    // Update the transcription record with the WAV URL
                    transcription.audioFileURL = wavURL.absoluteString
                } else {
                    audioURL = permanentURL
                }
            }

            // Update duration from actual audio
            let audioAsset = AVURLAsset(url: audioURL)
            let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))
            transcription.duration = duration

            try Task.checkCancellation()

            // Build strategy
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
                    audioURL: audioURL,
                    languageHint: job.languageHint,
                    progress: progressCallback
                )
            } catch LongAudioTranscriptionError.asyncJobsNotSupported {
                logger.info("Server doesn't support async jobs — falling back to client chunking")
                let fallbackStrategy = ClientChunkingStrategy(
                    serviceRegistry: serviceRegistry,
                    model: currentModel,
                    audioProcessor: audioProcessor
                )
                result = try await fallbackStrategy.transcribe(
                    audioURL: audioURL,
                    languageHint: job.languageHint,
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

            // Update the pre-existing transcription record
            transcription.text = text
            transcription.transcriptionModelName = currentModel.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.powerModeName = powerModeName
            transcription.powerModeEmoji = powerModeEmoji

            // Handle enhancement if enabled at drop time
            if job.isEnhancementEnabled,
               let enhancementService = engine.enhancementService,
               enhancementService.isConfigured {
                // Apply captured prompt selection
                if let promptId = job.selectedPromptId {
                    enhancementService.selectedPromptId = promptId
                }
                processingPhase = .enhancing
                do {
                    let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(text)
                    transcription.enhancedText = enhancedText
                    transcription.aiEnhancementModelName = enhancementService.getAIService()?.currentModel
                    transcription.promptName = promptName
                    transcription.enhancementDuration = enhancementDuration
                    transcription.aiRequestSystemMessage = enhancementService.lastSystemMessageSent
                    transcription.aiRequestUserMessage = enhancementService.lastUserMessageSent
                } catch {
                    logger.error("Enhancement failed: \(error.localizedDescription, privacy: .public)")
                }
            }

            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
            NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)

            processingPhase = .completed

        } catch {
            if error is CancellationError || (error as? TranscriptionError) == .transcriptionCancelled {
                logger.info("Transcription cancelled for \(transcription.originalFileName ?? "unknown", privacy: .public)")
                transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            } else {
                logger.error("Transcription error for \(transcription.originalFileName ?? "unknown", privacy: .public): \(error.localizedDescription, privacy: .public)")
                transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
                errorMessage = error.localizedDescription
            }
            try? modelContext.save()
        }
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
