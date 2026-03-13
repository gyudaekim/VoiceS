import Foundation
import Qwen3ASR
import os.log

class QwenTranscriptionService: TranscriptionService {
    private var model: Qwen3ASRModel?
    private var activeModelId: String?
    private let logger = Logger(subsystem: "com.gdkim.voices.qwen", category: "QwenTranscriptionService")

    private func modelId(for model: any TranscriptionModel) -> String {
        (model as? QwenModel)?.modelId ?? "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    }

    private func ensureModelLoaded(for targetModelId: String) async throws {
        if self.model != nil, activeModelId == targetModelId {
            return
        }

        // Clean up existing model
        self.model = nil
        activeModelId = nil

        let loaded = try await Qwen3ASRModel.fromPretrained(modelId: targetModelId)
        self.model = loaded
        self.activeModelId = targetModelId
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        let targetModelId = modelId(for: model)
        try await ensureModelLoaded(for: targetModelId)

        guard let qwenModel = self.model else {
            throw QwenTranscriptionError.notInitialized
        }

        let audioSamples = try readAudioSamples(from: audioURL)

        let result = qwenModel.transcribe(audio: audioSamples, sampleRate: 16000)

        return result
    }

    private func readAudioSamples(from url: URL) throws -> [Float] {
        do {
            let data = try Data(contentsOf: url)
            guard data.count > 44 else {
                throw QwenTranscriptionError.invalidAudioData
            }

            let floats = stride(from: 44, to: data.count, by: 2).map {
                return data[$0..<$0 + 2].withUnsafeBytes {
                    let short = Int16(littleEndian: $0.load(as: Int16.self))
                    return max(-1.0, min(Float(short) / 32767.0, 1.0))
                }
            }

            return floats
        } catch {
            throw QwenTranscriptionError.invalidAudioData
        }
    }

    func cleanup() {
        model = nil
        activeModelId = nil
    }
}

enum QwenTranscriptionError: LocalizedError {
    case notInitialized
    case invalidAudioData

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Qwen ASR model is not initialized"
        case .invalidAudioData:
            return "Invalid audio data"
        }
    }
}
