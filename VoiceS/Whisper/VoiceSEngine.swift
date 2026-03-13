import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import AppKit
import os

@MainActor
class VoiceSEngine: NSObject, ObservableObject {
    enum StartRecordingResult {
        case started
        case queueFull
        case noModel
        case busy
    }

    @Published var recordingState: RecordingState = .idle
    @Published var shouldCancelRecording = false
    @Published private(set) var pendingTranscriptionCount = 0
    @Published private(set) var backgroundState: BackgroundTranscriptionState = .idle

    var partialTranscript: String = ""
    var currentSession: TranscriptionSession?
    var isBackgroundProcessing: Bool { backgroundState != .idle || !queuedTranscriptionJobs.isEmpty }

    let recorder = Recorder()
    var recordedFile: URL? = nil
    let recordingsDirectory: URL

    // Injected managers
    let whisperModelManager: WhisperModelManager
    let transcriptionModelManager: TranscriptionModelManager
    weak var recorderUIManager: RecorderUIManager?

    let modelContext: ModelContext
    internal let serviceRegistry: TranscriptionServiceRegistry
    let enhancementService: AIEnhancementService?
    private let pipeline: TranscriptionPipeline

    let logger = Logger(subsystem: "com.gdkim.voices", category: "VoiceSEngine")

    private let maxQueuedTranscriptions = 10
    private var queuedTranscriptionJobs: [QueuedTranscriptionJob] = []
    private var isProcessingQueue = false

    private struct ActiveRecording {
        let audioURL: URL
        let model: any TranscriptionModel
        let session: TranscriptionSession?
    }

    private var activeRecording: ActiveRecording?

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil
    ) {
        self.modelContext = modelContext
        self.whisperModelManager = whisperModelManager
        self.transcriptionModelManager = transcriptionModelManager
        self.enhancementService = enhancementService

        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.gdkim.VoiceS")
        self.recordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings")

        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )
        self.pipeline = TranscriptionPipeline(
            modelContext: modelContext,
            serviceRegistry: serviceRegistry,
            enhancementService: enhancementService
        )

        super.init()

        if let enhancementService {
            PowerModeSessionManager.shared.configure(engine: self, enhancementService: enhancementService)
        }

        setupNotifications()
        createRecordingsDirectoryIfNeeded()
        markStalePendingTranscriptions()
        refreshPendingTranscriptionCount()
    }

    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("Error creating recordings directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func markStalePendingTranscriptions() {
        let descriptor = FetchDescriptor<Transcription>()

        guard let pending = try? modelContext.fetch(descriptor).filter({
            $0.transcriptionStatus == TranscriptionStatus.pending.rawValue
        }), !pending.isEmpty else {
            return
        }

        for transcription in pending {
            transcription.text = "Transcription Failed: VoiceS was closed before processing finished."
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        }

        try? modelContext.save()
    }

    func getEnhancementService() -> AIEnhancementService? {
        enhancementService
    }

    func startRecordingIfPossible(powerModeId: UUID? = nil) async -> StartRecordingResult {
        logger.notice("startRecordingIfPossible called – state=\(String(describing: self.recordingState), privacy: .public), pending=\(self.pendingTranscriptionCount, privacy: .public)")

        guard recordingState != .busy && recordingState != .starting else {
            return .busy
        }

        guard recordingState != .recording else {
            return .busy
        }

        guard outstandingTranscriptionJobCount < maxQueuedTranscriptions else {
            await NotificationManager.shared.showNotification(
                title: "Transcription queue is full",
                type: .warning
            )
            return .queueFull
        }

        guard let model = transcriptionModelManager.currentTranscriptionModel else {
            await NotificationManager.shared.showNotification(title: "No AI Model Selected", type: .error)
            return .noModel
        }

        shouldCancelRecording = false
        partialTranscript = ""
        recordingState = .starting

        let didStart = await beginRecording(using: model, powerModeId: powerModeId)
        return didStart ? .started : .busy
    }

    func toggleRecord(powerModeId: UUID? = nil) async {
        logger.notice("toggleRecord called – state=\(String(describing: self.recordingState), privacy: .public)")

        if recordingState == .recording {
            await stopActiveRecording()
        } else {
            _ = await startRecordingIfPossible(powerModeId: powerModeId)
        }
    }

    private func requestRecordPermission(response: @escaping (Bool) -> Void) {
        response(true)
    }

    private func beginRecording(using model: any TranscriptionModel, powerModeId: UUID?) async -> Bool {
        await withCheckedContinuation { continuation in
            requestRecordPermission { [weak self] granted in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }

                guard granted else {
                    self.logger.error("Recording permission denied.")
                    self.recordingState = .idle
                    continuation.resume(returning: false)
                    return
                }

                Task { @MainActor in
                    do {
                        let fileName = "\(UUID().uuidString).wav"
                        let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
                        self.recordedFile = permanentURL

                        let pendingChunks = OSAllocatedUnfairLock(initialState: [Data]())
                        self.recorder.onAudioChunk = { data in
                            pendingChunks.withLock { $0.append(data) }
                        }

                        try await self.recorder.startRecording(toOutputFile: permanentURL)

                        guard !self.shouldCancelRecording else {
                            self.recorder.stopRecording()
                            self.recordedFile = nil
                            self.recordingState = .idle
                            continuation.resume(returning: false)
                            return
                        }

                        await ActiveWindowService.shared.applyConfiguration(powerModeId: powerModeId)

                        let session = self.serviceRegistry.createSession(
                            for: model,
                            onPartialTranscript: { [weak self] partial in
                                Task { @MainActor in
                                    self?.partialTranscript = partial
                                }
                            }
                        )
                        self.currentSession = session
                        let realCallback = try await session.prepare(model: model)

                        if let realCallback {
                            self.recorder.onAudioChunk = realCallback
                            let buffered = pendingChunks.withLock { chunks -> [Data] in
                                let result = chunks
                                chunks.removeAll()
                                return result
                            }
                            for chunk in buffered { realCallback(chunk) }
                        } else {
                            self.recorder.onAudioChunk = nil
                            pendingChunks.withLock { $0.removeAll() }
                        }

                        self.activeRecording = ActiveRecording(
                            audioURL: permanentURL,
                            model: model,
                            session: session
                        )
                        self.recordingState = .recording
                        self.logger.notice("Recording started successfully")
                        self.prewarmResources(for: model)
                        continuation.resume(returning: true)
                    } catch {
                        self.logger.error("Failed to start recording: \(error.localizedDescription, privacy: .public)")
                        await NotificationManager.shared.showNotification(title: "Recording failed to start", type: .error)
                        await self.recorderUIManager?.dismissMiniRecorder()
                        self.currentSession = nil
                        self.activeRecording = nil
                        self.recordedFile = nil
                        self.recordingState = .idle
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }

    private func stopActiveRecording() async {
        logger.notice("stopActiveRecording called")

        partialTranscript = ""
        await recorder.stopRecording()

        guard let activeRecording else {
            logger.error("No active recording found while stopping")
            currentSession?.cancel()
            currentSession = nil
            recordingState = .idle
            await cleanupResourcesIfPossible()
            return
        }

        let session = activeRecording.session
        currentSession = nil
        self.activeRecording = nil
        recordedFile = nil

        if shouldCancelRecording {
            session?.cancel()
            try? FileManager.default.removeItem(at: activeRecording.audioURL)
            recordingState = .idle
            shouldCancelRecording = false
            await cleanupResourcesIfPossible()
            return
        }

        let audioAsset = AVURLAsset(url: activeRecording.audioURL)
        let duration = (try? CMTimeGetSeconds(await audioAsset.load(.duration))) ?? 0.0

        let transcription = Transcription(
            text: "",
            duration: duration,
            audioFileURL: activeRecording.audioURL.absoluteString,
            transcriptionStatus: .pending
        )
        modelContext.insert(transcription)
        try? modelContext.save()
        NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

        let job = QueuedTranscriptionJob(
            id: UUID(),
            audioURL: activeRecording.audioURL,
            transcription: transcription,
            model: activeRecording.model,
            session: session,
            snapshot: makeSnapshot()
        )
        queuedTranscriptionJobs.append(job)
        refreshPendingTranscriptionCount()

        recordingState = .idle
        shouldCancelRecording = false
        await recorderUIManager?.closePanelAfterRecordingStop()
        await processQueuedJobsIfNeeded()
    }

    private func makeSnapshot() -> TranscriptionJobSnapshot {
        let activePowerModeConfig = PowerModeManager.shared.currentActiveConfiguration

        return TranscriptionJobSnapshot(
            appendTrailingSpace: UserDefaults.standard.bool(forKey: "AppendTrailingSpace"),
            isTextFormattingEnabled: UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled"),
            shouldAutoSend: activePowerModeConfig?.isAutoSendEnabled == true,
            powerModeName: activePowerModeConfig?.isEnabled == true ? activePowerModeConfig?.name : nil,
            powerModeEmoji: activePowerModeConfig?.isEnabled == true ? activePowerModeConfig?.emoji : nil,
            enhancementContext: enhancementService?.makeSnapshot()
        )
    }

    private func processQueuedJobsIfNeeded() async {
        guard !isProcessingQueue else { return }

        isProcessingQueue = true
        defer {
            isProcessingQueue = false
        }

        while !queuedTranscriptionJobs.isEmpty {
            let job = queuedTranscriptionJobs.removeFirst()
            refreshPendingTranscriptionCount()

            await pipeline.run(
                transcription: job.transcription,
                audioURL: job.audioURL,
                model: job.model,
                session: job.session,
                snapshot: job.snapshot,
                onBackgroundStateChange: { [weak self] state in
                    guard let self else { return }
                    self.backgroundState = state
                    self.refreshPendingTranscriptionCount()
                    self.recorderUIManager?.syncPanels()
                },
                shouldCancel: { false },
                onCleanup: { [weak self] in await self?.cleanupResourcesIfPossible() }
            )

            backgroundState = .idle
            refreshPendingTranscriptionCount()
            recorderUIManager?.syncPanels()
        }

        await cleanupResourcesIfPossible()
        recorderUIManager?.syncPanels()
    }

    private var outstandingTranscriptionJobCount: Int {
        queuedTranscriptionJobs.count + (backgroundState == .idle ? 0 : 1)
    }

    private func refreshPendingTranscriptionCount() {
        pendingTranscriptionCount = outstandingTranscriptionJobCount
    }

    private func prewarmResources(for model: any TranscriptionModel) {
        Task.detached { [weak self] in
            guard let self else { return }

            if model.provider == .local {
                if let localWhisperModel = await self.whisperModelManager.availableModels.first(where: { $0.name == model.name }),
                   await self.whisperModelManager.whisperContext == nil {
                    do {
                        try await self.whisperModelManager.loadModel(localWhisperModel)
                    } catch {
                        await self.logger.error("Model loading failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } else if let parakeetModel = model as? ParakeetModel {
                try? await self.serviceRegistry.parakeetTranscriptionService.loadModel(for: parakeetModel)
            }

            if let enhancementService = await self.enhancementService {
                await MainActor.run {
                    enhancementService.captureClipboardContext()
                }
                await enhancementService.captureScreenContext()
            }
        }
    }

    // MARK: - Resource Cleanup

    func cleanupResources() async {
        logger.notice("cleanupResources: releasing model resources")
        await whisperModelManager.cleanupResources()
        serviceRegistry.cleanup()
        logger.notice("cleanupResources: completed")
    }

    private func cleanupResourcesIfPossible() async {
        guard activeRecording == nil, backgroundState == .idle, queuedTranscriptionJobs.isEmpty else {
            return
        }
        await cleanupResources()
    }

    // MARK: - Notification Handling

    func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLicenseStatusChanged),
            name: .licenseStatusChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptChange),
            name: .promptDidChange,
            object: nil
        )
    }

    @objc func handleLicenseStatusChanged() {
        pipeline.licenseViewModel = LicenseViewModel()
    }

    @objc func handlePromptChange() {
        Task {
            let currentPrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt")
                ?? whisperModelManager.whisperPrompt.transcriptionPrompt
            if let context = whisperModelManager.whisperContext {
                await context.setPrompt(currentPrompt)
            }
        }
    }
}
