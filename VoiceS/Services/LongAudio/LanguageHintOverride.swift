import Foundation

/// Task-local override for the per-call language hint used during long-audio transcription.
///
/// The live-recording flow reads `UserDefaults.standard.string(forKey: "SelectedLanguage")`
/// directly. For the Transcribe Audio tab we want the user to pick a language *per run*
/// without mutating the global setting. Services that honor this override check
/// `LanguageHintOverride.current ?? UserDefaults.standard.string(forKey: "SelectedLanguage")`.
///
/// Because it's `@TaskLocal`, the override only applies within the `withValue` scope of a
/// specific Task tree — it won't leak into concurrent live-recording tasks.
///
/// Usage:
/// ```swift
/// try await LanguageHintOverride.$current.withValue("ko") {
///     try await serviceRegistry.transcribe(audioURL: chunkURL, model: currentModel)
/// }
/// ```
enum LanguageHintOverride {
    @TaskLocal static var current: String?
}
