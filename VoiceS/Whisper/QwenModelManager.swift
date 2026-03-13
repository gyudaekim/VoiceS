import Foundation
import Qwen3ASR
import AppKit
import os

@MainActor
class QwenModelManager: ObservableObject {
    @Published var qwenDownloadStates: [String: Bool] = [:]
    @Published var downloadProgress: [String: Double] = [:]

    /// Called when a model is deleted, passing the model name.
    /// TranscriptionModelManager listens to clear currentTranscriptionModel if needed.
    var onModelDeleted: ((String) -> Void)?

    /// Called after a model is successfully downloaded so TranscriptionModelManager
    /// can rebuild allAvailableModels.
    var onModelsChanged: (() -> Void)?

    private let logger = Logger(subsystem: "com.gdkim.voices", category: "QwenModelManager")

    init() {}

    // MARK: - Query helpers

    func isQwenModelDownloaded(named modelName: String) -> Bool {
        UserDefaults.standard.bool(forKey: qwenDefaultsKey(for: modelName))
    }

    func isQwenModelDownloaded(_ model: QwenModel) -> Bool {
        isQwenModelDownloaded(named: model.name)
    }

    func isQwenModelDownloading(_ model: QwenModel) -> Bool {
        qwenDownloadStates[model.name] ?? false
    }

    // MARK: - Download

    func downloadQwenModel(_ model: QwenModel) async {
        if isQwenModelDownloaded(model) {
            return
        }

        let modelName = model.name
        qwenDownloadStates[modelName] = true
        downloadProgress[modelName] = 0.0

        do {
            _ = try await Qwen3ASRModel.fromPretrained(modelId: model.modelId) { [weak self] progress, _ in
                Task { @MainActor in
                    self?.downloadProgress[modelName] = progress
                }
            }

            UserDefaults.standard.set(true, forKey: qwenDefaultsKey(for: modelName))
            downloadProgress[modelName] = 1.0
        } catch {
            UserDefaults.standard.set(false, forKey: qwenDefaultsKey(for: modelName))
            logger.error("❌ Qwen download failed for \(modelName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        qwenDownloadStates[modelName] = false
        downloadProgress[modelName] = nil

        onModelsChanged?()
    }

    // MARK: - Delete

    func deleteQwenModel(_ model: QwenModel) {
        let cacheDirectory = qwenCacheDirectory(for: model)

        do {
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.removeItem(at: cacheDirectory)
            }
            UserDefaults.standard.set(false, forKey: qwenDefaultsKey(for: model.name))
        } catch {
            // Silently ignore removal errors
        }

        onModelDeleted?(model.name)
    }

    // MARK: - Finder

    func showQwenModelInFinder(_ model: QwenModel) {
        let cacheDirectory = qwenCacheDirectory(for: model)

        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            NSWorkspace.shared.selectFile(cacheDirectory.path, inFileViewerRootedAtPath: "")
        }
    }

    // MARK: - Private helpers

    private func qwenDefaultsKey(for modelName: String) -> String {
        "QwenModelDownloaded_\(modelName)"
    }

    private func qwenCacheDirectory(for model: QwenModel) -> URL {
        let sanitizedId = model.modelId.replacingOccurrences(of: "/", with: "_")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/qwen3-speech")
            .appendingPathComponent(sanitizedId)
    }
}
