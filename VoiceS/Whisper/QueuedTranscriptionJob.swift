import Foundation

enum BackgroundTranscriptionState: Equatable {
    case idle
    case transcribing
    case enhancing
}

struct EnhancementContextSnapshot {
    let isEnabled: Bool
    let selectedPromptId: UUID?
    let prompts: [CustomPrompt]
    let useClipboardContext: Bool
    let useScreenCaptureContext: Bool
    let capturedClipboardText: String?
    let capturedScreenText: String?
}

struct TranscriptionJobSnapshot {
    let appendTrailingSpace: Bool
    let isTextFormattingEnabled: Bool
    let shouldAutoSend: Bool
    let powerModeName: String?
    let powerModeEmoji: String?
    let enhancementContext: EnhancementContextSnapshot?
}

@MainActor
struct QueuedTranscriptionJob {
    let id: UUID
    let audioURL: URL
    let transcription: Transcription
    let model: any TranscriptionModel
    let session: TranscriptionSession?
    let snapshot: TranscriptionJobSnapshot
}
