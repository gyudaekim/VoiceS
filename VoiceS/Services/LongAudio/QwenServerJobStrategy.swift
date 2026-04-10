import Foundation
import os

/// Uploads the audio file as-is to the gdk-server Qwen3-ASR async job API, polls for
/// progress, and fetches the final Markdown result. The server handles chunking,
/// overlap, and dedup internally, so the client just surfaces status updates and waits.
///
/// Server contract (see `http://10.78.151.244:8000/openapi.json`):
/// - `POST {base}/v1/jobs/transcriptions`  multipart with `file` + `language` → `{job_id, …}`
/// - `GET  {base}/v1/jobs/{id}`              poll for status/progress
/// - `GET  {base}/v1/jobs/{id}/result.md`   final Markdown on completion
@MainActor
final class QwenServerJobStrategy: LongAudioTranscriptionStrategy {
    private let baseURL: URL
    private let apiKey: String?
    private let logger = Logger(subsystem: "com.gdkim.voices", category: "QwenServerJobStrategy")
    private let pollInterval: UInt64 = 2_500_000_000 // 2.5 s in nanoseconds
    /// Maximum wall-clock polling duration before giving up (2 hours).
    private let maxPollDuration: TimeInterval = 7200

    init(baseURL: URL, apiKey: String?) {
        self.baseURL = baseURL
        self.apiKey = apiKey?.isEmpty == false ? apiKey : nil
    }

    /// Transforms an OpenAI-compatible `/v1/audio/transcriptions` endpoint into the base
    /// URL used by the async job API. Returns nil for endpoints that don't match the
    /// expected shape — the caller should fall back to client-side chunking in that case.
    ///
    /// Examples:
    /// - `https://asr.synrz.com/v1/audio/transcriptions` → `https://asr.synrz.com`
    /// - `https://asr.synrz.com/v1/audio/transcriptions?q=1` → `https://asr.synrz.com`
    /// - `https://asr.synrz.com/v1/audio/transcriptions/` → `https://asr.synrz.com` (trailing slash tolerated)
    /// - `https://example.com/other/path` → nil
    static func deriveBaseURL(from endpoint: String) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        // Normalize: strip trailing slash before the suffix check so
        // "https://host/v1/audio/transcriptions/" is handled correctly.
        while components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        let expectedSuffix = "/v1/audio/transcriptions"
        guard components.path.hasSuffix(expectedSuffix) else { return nil }
        components.path = String(components.path.dropLast(expectedSuffix.count))
        components.query = nil
        components.fragment = nil
        // Strip embedded credentials (user:pass@host) to avoid leaking them in requests.
        components.user = nil
        components.password = nil
        // Strip any remaining trailing slash for a canonical base.
        while components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url
    }

    func transcribe(
        audioURL: URL,
        languageHint: String,
        progress: @escaping (LongAudioProgress) -> Void
    ) async throws -> LongAudioResult {
        // Pre-probe: verify this server supports the async job API by hitting /health.
        // Prevents false-positive matches on generic OpenAI-compatible endpoints (e.g.,
        // api.openai.com) which have the same /v1/audio/transcriptions path shape but
        // no /v1/jobs/* surface.
        try await verifyServerSupportsAsyncJobs()

        progress(LongAudioProgress(
            status: .uploading,
            message: "Uploading audio to server…",
            progressPercent: 0
        ))

        let jobId = try await submitJob(audioURL: audioURL, languageHint: languageHint)
        // Validate jobId shape — the server controls this value and we interpolate it into URL paths.
        guard jobId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw LongAudioTranscriptionError.invalidServerResponse("Invalid job_id format: \(jobId.prefix(50))")
        }
        logger.info("Created job \(jobId, privacy: .public)")

        let finalStatus = try await pollUntilTerminal(jobId: jobId, progress: progress)

        switch finalStatus.terminal {
        case .completed:
            let markdown = try await fetchResultMarkdown(jobId: jobId, resultURLHint: finalStatus.resultURL)
            let plainText = Self.stripMarkdownHeaders(markdown)

            progress(LongAudioProgress(
                status: .completed,
                message: "Completed",
                currentChunk: finalStatus.currentChunk,
                totalChunks: finalStatus.totalChunks,
                progressPercent: 100,
                detectedLanguage: finalStatus.detectedLanguage
            ))

            return LongAudioResult(
                text: plainText,
                markdown: markdown,
                detectedLanguage: finalStatus.detectedLanguage
            )

        case .failed:
            let message = finalStatus.message ?? "Server reported failure"
            throw LongAudioTranscriptionError.serverFailed(message)
        }
    }

    // MARK: - Health check pre-probe

    /// Quick health check to confirm the server at `baseURL` is actually a Qwen ASR server
    /// with async job support, not a generic OpenAI-compatible host.
    private func verifyServerSupportsAsyncJobs() async throws {
        let healthURL = baseURL.appendingPathComponent("/health")
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        if let apiKey = apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw LongAudioTranscriptionError.asyncJobsNotSupported
            }
            // Verify the response looks like a Qwen ASR health check (has "status": "ok").
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["status"] as? String == "ok" {
                logger.info("Server health check passed")
            } else {
                throw LongAudioTranscriptionError.asyncJobsNotSupported
            }
        } catch let error as LongAudioTranscriptionError {
            throw error
        } catch {
            // Network error, timeout, etc. — server is not reachable at this base URL.
            throw LongAudioTranscriptionError.asyncJobsNotSupported
        }
    }

    // MARK: - Submit

    private func submitJob(audioURL: URL, languageHint: String) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("/v1/jobs/transcriptions")
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey = apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let bodyFileURL = try prepareMultipartBody(
            audioURL: audioURL,
            languageHint: languageHint,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: bodyFileURL) }

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyFileURL)
        try Self.validate(response: response, data: data, context: "submitJob")

        guard let job = try? JSONDecoder().decode(JobStatusResponse.self, from: data),
              let jobId = job.jobId else {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw LongAudioTranscriptionError.invalidServerResponse("Missing job_id in response: \(raw.prefix(200))")
        }
        return jobId
    }

    /// Sanitize a string for safe interpolation into a multipart header. Strips CR/LF to
    /// prevent header injection.
    private static func sanitizeForHeader(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "")
             .replacingOccurrences(of: "\n", with: "")
    }

    private func prepareMultipartBody(
        audioURL: URL,
        languageHint: String,
        boundary: String
    ) throws -> URL {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("voices-upload-\(UUID().uuidString).multipart")

        guard FileManager.default.createFile(atPath: tempFile.path, contents: nil) else {
            throw LongAudioTranscriptionError.invalidServerResponse("Failed to create temp upload file")
        }

        // Restrict temp file permissions to owner-only (0600) since it contains audio data.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: tempFile.path
        )

        let handle = try FileHandle(forWritingTo: tempFile)
        defer { try? handle.close() }

        let crlf = "\r\n"
        func write(_ string: String) throws {
            guard let data = string.data(using: .utf8) else { return }
            try handle.write(contentsOf: data)
        }

        // File part header — sanitize filename to prevent CRLF injection.
        let safeFilename = Self.sanitizeForHeader(audioURL.lastPathComponent)
        try write("--\(boundary)\(crlf)")
        try write("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\(crlf)")
        try write("Content-Type: application/octet-stream\(crlf)\(crlf)")

        // Stream the file contents in 1 MiB chunks so a one-hour file doesn't balloon memory.
        let inputHandle = try FileHandle(forReadingFrom: audioURL)
        defer { try? inputHandle.close() }
        let chunkSize = 1 << 20
        while true {
            let chunk = try autoreleasepool { () -> Data? in
                return try inputHandle.read(upToCount: chunkSize)
            }
            guard let chunk = chunk, !chunk.isEmpty else { break }
            try handle.write(contentsOf: chunk)
        }
        try write(crlf)

        // Language part (only if non-auto, matching the server UI's behavior)
        let trimmedLang = Self.sanitizeForHeader(languageHint.trimmingCharacters(in: .whitespaces))
        if !trimmedLang.isEmpty, trimmedLang != "auto" {
            try write("--\(boundary)\(crlf)")
            try write("Content-Disposition: form-data; name=\"language\"\(crlf)\(crlf)")
            try write(trimmedLang)
            try write(crlf)
        }

        try write("--\(boundary)--\(crlf)")
        return tempFile
    }

    // MARK: - Poll

    private struct FinalStatus {
        enum Terminal { case completed, failed }
        let terminal: Terminal
        let message: String?
        let currentChunk: Int?
        let totalChunks: Int?
        let detectedLanguage: String?
        let resultURL: String?
    }

    private func pollUntilTerminal(
        jobId: String,
        progress: @escaping (LongAudioProgress) -> Void
    ) async throws -> FinalStatus {
        let statusURL = baseURL.appendingPathComponent("/v1/jobs/\(jobId)")
        var request = URLRequest(url: statusURL)
        request.httpMethod = "GET"
        if let apiKey = apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let pollStart = Date()

        while true {
            try Task.checkCancellation()

            // Wall-clock timeout guard.
            if Date().timeIntervalSince(pollStart) > maxPollDuration {
                throw LongAudioTranscriptionError.pollingTimeout
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.validate(response: response, data: data, context: "pollJob")

            let job = try JSONDecoder().decode(JobStatusResponse.self, from: data)
            let mapped = mapStatus(job)

            // Clamp server-reported progress to 0–100 for safe ProgressView binding.
            let clampedPercent: Double? = job.progressPercent.map { max(0, min(100, $0)) }

            progress(LongAudioProgress(
                status: mapped,
                message: job.message ?? "",
                currentChunk: job.currentChunk,
                totalChunks: job.totalChunks,
                progressPercent: clampedPercent,
                detectedLanguage: job.detectedLanguage
            ))

            switch mapped {
            case .completed:
                return FinalStatus(
                    terminal: .completed,
                    message: job.message,
                    currentChunk: job.currentChunk,
                    totalChunks: job.totalChunks,
                    detectedLanguage: job.detectedLanguage,
                    resultURL: job.resultUrl
                )
            case .failed:
                return FinalStatus(
                    terminal: .failed,
                    message: job.message,
                    currentChunk: job.currentChunk,
                    totalChunks: job.totalChunks,
                    detectedLanguage: job.detectedLanguage,
                    resultURL: nil
                )
            case .idle, .queued, .uploading, .running:
                try await Task.sleep(nanoseconds: pollInterval)
            }
        }
    }

    private func mapStatus(_ job: JobStatusResponse) -> LongAudioProgress.Status {
        switch job.status.lowercased() {
        case "completed": return .completed
        case "failed", "error": return .failed
        case "queued": return .queued
        case "uploading": return .uploading
        case "running", "processing": return .running
        case "idle": return .idle
        default:
            logger.warning("Unknown server job status: \(job.status, privacy: .public) — treating as .running")
            return .running
        }
    }

    // MARK: - Fetch result

    private func fetchResultMarkdown(jobId: String, resultURLHint: String?) async throws -> String {
        // Build the result URL. Only trust server-provided result_url if it matches our base
        // origin — prevents SSRF / Bearer-token exfiltration to an attacker-controlled host.
        let resultURL: URL = {
            if let hint = resultURLHint,
               let parsed = URL(string: hint),
               parsed.scheme != nil,
               parsed.host == baseURL.host, parsed.scheme == baseURL.scheme {
                return parsed
            }
            if let hint = resultURLHint,
               let parsed = URL(string: hint, relativeTo: baseURL)?.absoluteURL,
               parsed.host == baseURL.host {
                return parsed
            }
            return baseURL.appendingPathComponent("/v1/jobs/\(jobId)/result.md")
        }()

        var request = URLRequest(url: resultURL)
        request.httpMethod = "GET"
        if let apiKey = apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data, context: "fetchResult")

        guard let text = String(data: data, encoding: .utf8) else {
            throw LongAudioTranscriptionError.invalidServerResponse("Result body was not UTF-8")
        }
        return text
    }

    // MARK: - Helpers

    private static func validate(response: URLResponse, data: Data, context: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LongAudioTranscriptionError.invalidServerResponse("\(context): missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LongAudioTranscriptionError.serverFailed("\(context) HTTP \(http.statusCode): \(body.prefix(200))")
        }
    }

    /// Removes the leading `# Title` and `**Key:** Value` metadata block produced by the
    /// server, leaving the body text for display and SwiftData storage.
    ///
    /// Stops consuming lines after passing through the metadata block (H1 + bold lines).
    /// A blank line following the metadata signals the start of body text, preventing the
    /// function from greedily eating body paragraphs that happen to start with `**`.
    private static func stripMarkdownHeaders(_ markdown: String) -> String {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Drop leading blank lines
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        // Drop a single H1 line if present
        if let first = lines.first, first.hasPrefix("# ") {
            lines.removeFirst()
        }
        // Drop the metadata block: lines that are blank or match **Key:** pattern.
        // Stop at the first blank line AFTER at least one metadata line — that blank line
        // is the separator between metadata and body, not more metadata.
        var seenMetadata = false
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if seenMetadata {
                    // Blank line after metadata = end of metadata block; drop this separator
                    // and stop stripping.
                    lines.removeFirst()
                    break
                }
                // Blank line before any metadata — still part of the leading whitespace.
                lines.removeFirst()
            } else if trimmed.hasPrefix("**") && trimmed.contains(":") {
                // Metadata line like **Date:** 2026-04-10
                seenMetadata = true
                lines.removeFirst()
            } else {
                // Non-blank, non-metadata — this is the start of the body.
                break
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Wire types

    private struct JobStatusResponse: Decodable {
        let jobId: String?
        let status: String
        let message: String?
        let progressPercent: Double?
        let currentChunk: Int?
        let totalChunks: Int?
        let detectedLanguage: String?
        let resultUrl: String?

        enum CodingKeys: String, CodingKey {
            case jobId = "job_id"
            case status
            case message
            case progressPercent = "progress_percent"
            case currentChunk = "current_chunk"
            case totalChunks = "total_chunks"
            case detectedLanguage = "detected_language"
            case resultUrl = "result_url"
        }
    }
}
