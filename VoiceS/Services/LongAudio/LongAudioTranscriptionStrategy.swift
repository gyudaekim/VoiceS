import Foundation

/// Progress update emitted by a `LongAudioTranscriptionStrategy` during transcription.
/// Maps loosely to the `/v1/jobs/{id}` response shape on the gdk-server Qwen ASR API.
struct LongAudioProgress: Equatable {
    var status: Status
    var message: String
    var currentChunk: Int?
    var totalChunks: Int?
    var progressPercent: Double?   // 0...100
    var detectedLanguage: String?

    enum Status: String, Equatable {
        case idle
        case uploading
        case queued
        case running
        case completed
        case failed
    }

    static let idle = LongAudioProgress(status: .idle, message: "")

    /// Format `current / total` for UI display. Returns nil if either is missing.
    var chunkLabel: String? {
        guard let current = currentChunk, let total = totalChunks else { return nil }
        return "\(current) / \(total)"
    }
}

/// Final result from a long-audio transcription run.
/// Both plain and markdown forms are provided; plain text is what gets saved in SwiftData.
struct LongAudioResult {
    /// Plain concatenated text (post overlap-dedup for client chunking, post Markdown-strip for server).
    let text: String
    /// Markdown representation for download. For server strategy this is the raw server-generated
    /// Markdown; for client strategy this is a simple wrapper built locally.
    let markdown: String
    /// Language detected by the model/server, if any.
    let detectedLanguage: String?
}

/// A strategy for transcribing long audio files (potentially hours long).
/// Two implementations exist:
/// - `QwenServerJobStrategy`: delegates chunking to the gdk-server async job API.
/// - `ClientChunkingStrategy`: chunks on-device and dispatches per-chunk to the regular
///   `TranscriptionServiceRegistry` for any other model.
///
/// Both implementations are main-actor bound to match `AudioTranscriptionManager` and
/// `TranscriptionServiceRegistry`. The progress callback is invoked directly on the main
/// actor so callers can mutate `@Published` state without hopping.
@MainActor
protocol LongAudioTranscriptionStrategy {
    /// Transcribes the full audio file, streaming progress updates via the callback.
    /// Must respect `Task.isCancelled` and throw `CancellationError` when cancelled.
    func transcribe(
        audioURL: URL,
        languageHint: String,
        progress: @escaping (LongAudioProgress) -> Void
    ) async throws -> LongAudioResult
}

enum LongAudioTranscriptionError: LocalizedError {
    case cancelled
    case serverFailed(String)
    case invalidServerResponse(String)
    case missingModel
    /// The server at the derived base URL does not support the async job API.
    /// The caller should fall back to `ClientChunkingStrategy`.
    case asyncJobsNotSupported
    case pollingTimeout

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Transcription was cancelled"
        case .serverFailed(let message):
            return "Server transcription failed: \(message)"
        case .invalidServerResponse(let message):
            return "Invalid server response: \(message)"
        case .missingModel:
            return "No transcription model selected"
        case .asyncJobsNotSupported:
            return "Server does not support the async job transcription API"
        case .pollingTimeout:
            return "Server did not complete transcription within the expected time"
        }
    }
}
