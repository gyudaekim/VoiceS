import Foundation

/// Protocol for objects that can serve as the recorder's state source.
/// VoiceSEngine conforms to this protocol.
@MainActor
protocol RecorderStateProvider: AnyObject {
    var recordingState: RecordingState { get }
    var backgroundState: BackgroundTranscriptionState { get }
    var partialTranscript: String { get }
    var pendingTranscriptionCount: Int { get }
    var isBackgroundProcessing: Bool { get }
    var enhancementService: AIEnhancementService? { get }
}
