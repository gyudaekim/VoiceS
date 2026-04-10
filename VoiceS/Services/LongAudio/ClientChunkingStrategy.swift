import Foundation
import os

/// Splits the audio into fixed-length overlapping windows on-device, transcribes each
/// window through the existing `TranscriptionServiceRegistry` (which respects the currently
/// selected model), then merges the per-chunk text with overlap dedup.
///
/// This is the fallback path for any model that isn't the gdk-server Qwen3-ASR async job
/// API — Whisper local, Qwen MLX local, Parakeet, Native Apple, and OpenAI-compatible cloud
/// models all go through here from the Transcribe Audio tab.
@MainActor
final class ClientChunkingStrategy: LongAudioTranscriptionStrategy {
    private let serviceRegistry: TranscriptionServiceRegistry
    private let model: any TranscriptionModel
    private let audioProcessor: AudioProcessor
    private let logger = Logger(subsystem: "com.gdkim.voices", category: "ClientChunkingStrategy")

    init(
        serviceRegistry: TranscriptionServiceRegistry,
        model: any TranscriptionModel,
        audioProcessor: AudioProcessor
    ) {
        self.serviceRegistry = serviceRegistry
        self.model = model
        self.audioProcessor = audioProcessor
    }

    func transcribe(
        audioURL: URL,
        languageHint: String,
        progress: @escaping (LongAudioProgress) -> Void
    ) async throws -> LongAudioResult {
        progress(LongAudioProgress(
            status: .running,
            message: "Preparing audio…",
            currentChunk: nil,
            totalChunks: nil,
            progressPercent: 0,
            detectedLanguage: nil
        ))

        let samples = try await audioProcessor.processAudioToSamples(audioURL)
        try Task.checkCancellation()

        let chunks = AudioChunker.chunk(samples: samples)
        guard !chunks.isEmpty else {
            throw LongAudioTranscriptionError.invalidServerResponse("Audio produced zero samples")
        }
        let totalChunks = chunks.count
        logger.info("Chunked audio into \(totalChunks, privacy: .public) window(s) of ~\(Int(AudioChunker.defaultWindowSeconds), privacy: .public)s")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voices-longaudio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let effectiveHint: String? = {
            let trimmed = languageHint.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "auto" { return nil }
            return trimmed
        }()

        var chunkTexts: [String] = []
        chunkTexts.reserveCapacity(totalChunks)

        for chunk in chunks {
            try Task.checkCancellation()

            let chunkURL = tempDir.appendingPathComponent("chunk-\(chunk.index).wav")
            try audioProcessor.saveSamplesAsWav(samples: chunk.samples, to: chunkURL)

            progress(LongAudioProgress(
                status: .running,
                message: "Transcribing chunk \(chunk.index + 1) of \(totalChunks)…",
                currentChunk: chunk.index + 1,
                totalChunks: totalChunks,
                progressPercent: Double(chunk.index) / Double(totalChunks) * 100.0,
                detectedLanguage: effectiveHint
            ))

            let chunkText: String
            do {
                chunkText = try await LanguageHintOverride.$current.withValue(effectiveHint) {
                    try await serviceRegistry.transcribe(audioURL: chunkURL, model: model)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.error("❌ Chunk \(chunk.index + 1, privacy: .public)/\(totalChunks, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }

            chunkTexts.append(chunkText)
            do {
                try FileManager.default.removeItem(at: chunkURL)
            } catch {
                logger.warning("Failed to remove chunk WAV \(chunkURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            progress(LongAudioProgress(
                status: .running,
                message: "Chunk \(chunk.index + 1) of \(totalChunks) complete",
                currentChunk: chunk.index + 1,
                totalChunks: totalChunks,
                progressPercent: Double(chunk.index + 1) / Double(totalChunks) * 100.0,
                detectedLanguage: effectiveHint
            ))
        }

        let mergedText = ChunkTextMerger.merge(chunkTexts: chunkTexts)
        let markdown = Self.buildMarkdown(
            text: mergedText,
            sourceFileName: audioURL.lastPathComponent,
            chunkCount: totalChunks,
            modelDisplayName: model.displayName
        )

        return LongAudioResult(
            text: mergedText,
            markdown: markdown,
            detectedLanguage: effectiveHint
        )
    }

    // MARK: - Markdown wrapper

    private static func buildMarkdown(
        text: String,
        sourceFileName: String,
        chunkCount: Int,
        modelDisplayName: String
    ) -> String {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        return """
        # Transcription

        **Source:** \(sourceFileName)
        **Date:** \(timestamp)
        **Model:** \(modelDisplayName)
        **Chunks:** \(chunkCount)

        \(text)
        """
    }
}
