import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AVFoundation

struct AudioTranscribeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var engine: VoiceSEngine
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @StateObject private var transcriptionManager = AudioTranscriptionManager.shared
    @Query(
        filter: #Predicate<Transcription> { $0.source == "file" },
        sort: \Transcription.timestamp,
        order: .reverse
    ) private var fileTranscriptions: [Transcription]
    @State private var isDropTargeted = false
    @State private var selectedAudioURL: URL?
    @State private var isAudioFileSelected = false
    @State private var isEnhancementEnabled = false
    @State private var selectedPromptId: UUID?
    @State private var showFullHistory = false
    @AppStorage("TranscribeAudioLanguage") private var selectedLanguage: String = "auto"

    private let languageOptions: [(code: String, label: String)] = [
        ("auto", "Auto-detect"),
        ("en", "English"),
        ("ko", "Korean"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German")
    ]

    // Custom sort: in-progress first, then queued, then completed/failed by date
    private var sortedFileTranscriptions: [Transcription] {
        fileTranscriptions.sorted { a, b in
            let orderA = statusSortOrder(a.transcriptionStatus)
            let orderB = statusSortOrder(b.transcriptionStatus)
            if orderA != orderB { return orderA < orderB }
            return a.timestamp > b.timestamp
        }
    }

    private func statusSortOrder(_ status: String?) -> Int {
        switch status {
        case TranscriptionStatus.inProgress.rawValue: return 0
        case TranscriptionStatus.queued.rawValue: return 1
        default: return 2
        }
    }

    var body: some View {
        ZStack {
            Color(NSColor.controlBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                dropZoneView

                Divider()
                    .padding(.vertical)

                fileTranscriptionHistorySection
            }
        }
        .sheet(isPresented: $showFullHistory) {
            fileTranscriptionFullHistorySheet
        }
        .onDrop(of: [.fileURL, .data, .audio, .movie], isTargeted: $isDropTargeted) { providers in
            handleDroppedFiles(providers)
            return true
        }
        .alert("Error", isPresented: .constant(transcriptionManager.errorMessage != nil)) {
            Button("OK", role: .cancel) {
                transcriptionManager.errorMessage = nil
            }
        } message: {
            if let errorMessage = transcriptionManager.errorMessage {
                Text(errorMessage)
            }
        }
        .onAppear {
            transcriptionManager.cleanupStaleJobs(modelContext: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFileForTranscription)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                validateAndSetAudioFile(url)
            }
        }
    }

    // MARK: - Drop Zone

    private var dropZoneView: some View {
        VStack(spacing: 16) {
            if isAudioFileSelected {
                VStack(spacing: 16) {
                    Text("Audio file selected: \(selectedAudioURL?.lastPathComponent ?? "")")
                        .font(.headline)

                    // AI Enhancement Settings
                    VStack(spacing: 16) {
                        HStack(spacing: 16) {
                            Toggle("AI Enhancement", isOn: $isEnhancementEnabled)
                                .toggleStyle(.switch)
                                .onChange(of: isEnhancementEnabled) { oldValue, newValue in
                                    enhancementService.isEnhancementEnabled = newValue
                                }

                            if isEnhancementEnabled {
                                Divider()
                                    .frame(height: 20)

                                HStack(spacing: 8) {
                                    Text("Prompt:")
                                        .font(.subheadline)

                                    if enhancementService.allPrompts.isEmpty {
                                        Text("No prompts available")
                                            .foregroundColor(.secondary)
                                            .italic()
                                            .font(.caption)
                                    } else {
                                        let promptBinding = Binding<UUID>(
                                            get: {
                                                selectedPromptId ?? enhancementService.allPrompts.first?.id ?? UUID()
                                            },
                                            set: { newValue in
                                                selectedPromptId = newValue
                                                enhancementService.selectedPromptId = newValue
                                            }
                                        )

                                        Picker("", selection: promptBinding) {
                                            ForEach(enhancementService.allPrompts) { prompt in
                                                Text(prompt.title).tag(prompt.id)
                                            }
                                        }
                                        .labelsHidden()
                                        .fixedSize()
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(CardBackground(isSelected: false))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .onAppear {
                        isEnhancementEnabled = enhancementService.isEnhancementEnabled
                        selectedPromptId = enhancementService.selectedPromptId
                    }

                    // Language hint picker
                    HStack(spacing: 8) {
                        Text("Language:")
                            .font(.subheadline)
                        Picker("", selection: $selectedLanguage) {
                            ForEach(languageOptions, id: \.code) { option in
                                Text(option.label).tag(option.code)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(CardBackground(isSelected: false))

                    // Action Buttons
                    HStack(spacing: 12) {
                        Button("Start Transcription") {
                            if let url = selectedAudioURL {
                                transcriptionManager.startProcessing(
                                    url: url,
                                    modelContext: modelContext,
                                    engine: engine,
                                    languageHint: selectedLanguage,
                                    isEnhancementEnabled: isEnhancementEnabled,
                                    selectedPromptId: selectedPromptId
                                )
                                // Auto-deselect so drop zone is ready for next file
                                selectedAudioURL = nil
                                isAudioFileSelected = false
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Choose Different File") {
                            selectFile()
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            selectedAudioURL = nil
                            isAudioFileSelected = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.secondary)
                        .help("Clear selection")
                    }
                }
                .padding()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.windowBackgroundColor).opacity(0.4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    style: StrokeStyle(
                                        lineWidth: 2,
                                        dash: [8]
                                    )
                                )
                                .foregroundColor(isDropTargeted ? .blue : .gray.opacity(0.5))
                        )

                    VStack(spacing: 16) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 32))
                            .foregroundColor(isDropTargeted ? .blue : .gray)

                        Text("Drop audio or video files here")
                            .font(.headline)

                        Text("or")
                            .foregroundColor(.secondary)

                        Button("Choose Files") {
                            selectFile()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(32)
                }
                .frame(height: 200)
                .padding(.horizontal)
            }

            Text("Supported formats: WAV, MP3, M4A, AIFF, MP4, MOV, AAC, FLAC, CAF, AMR, OGG, OPUS, 3GP")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    // MARK: - File Transcription History

    private var fileTranscriptionHistorySection: some View {
        Group {
            if sortedFileTranscriptions.isEmpty {
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Transcriptions")
                            .font(.headline)
                        Spacer()
                        if transcriptionManager.isProcessing {
                            Button("Cancel") {
                                transcriptionManager.cancelProcessing()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)

                    ForEach(sortedFileTranscriptions.prefix(5)) { transcription in
                        fileTranscriptionRow(transcription)
                        if transcription.id != sortedFileTranscriptions.prefix(5).last?.id {
                            Divider().padding(.horizontal)
                        }
                    }

                    if sortedFileTranscriptions.count > 5 {
                        Button {
                            showFullHistory = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("View More (\(sortedFileTranscriptions.count) total)")
                                    .font(.subheadline)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        .padding(.vertical, 8)
                    }
                }
                Spacer()
            }
        }
    }

    private func fileTranscriptionRow(_ transcription: Transcription) -> some View {
        let displayName = transcription.originalFileName
            ?? URL(string: transcription.audioFileURL ?? "")?.lastPathComponent
            ?? "Unknown"
        let bestText = transcription.enhancedText ?? transcription.text
        let isActive = transcription.transcriptionStatus == TranscriptionStatus.queued.rawValue ||
                       transcription.transcriptionStatus == TranscriptionStatus.inProgress.rawValue

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.richtext")
                    .foregroundColor(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 8) {
                        if transcription.duration > 0 {
                            Text(formatDurationLong(transcription.duration))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Text(transcription.timestamp, style: .date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Status indicator
                statusIcon(for: transcription)

                // Copy button
                Button {
                    ClipboardManager.copyToClipboard(bestText)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .help("Copy transcription text")
                .disabled(isActive)

                // Save as Markdown button
                Button {
                    saveAsMarkdown(text: bestText, fileName: displayName)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .help("Save as Markdown")
                .disabled(isActive)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            // Compact inline progress for in-progress row
            if transcription.transcriptionStatus == TranscriptionStatus.inProgress.rawValue {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: transcriptionManager.longAudioProgress.progressPercent ?? 0, total: 100)
                        .progressViewStyle(.linear)
                        .frame(height: 4)
                    Text(transcriptionManager.processingPhase.message)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func statusIcon(for transcription: Transcription) -> some View {
        switch transcription.transcriptionStatus {
        case TranscriptionStatus.completed.rawValue:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.body)
        case TranscriptionStatus.failed.rawValue:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.body)
        case TranscriptionStatus.inProgress.rawValue:
            ProgressView()
                .controlSize(.small)
        case TranscriptionStatus.queued.rawValue:
            Image(systemName: "clock.fill")
                .foregroundColor(.orange)
                .font(.body)
        default:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.body)
        }
    }

    private var fileTranscriptionFullHistorySheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("All File Transcriptions")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    showFullHistory = false
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sortedFileTranscriptions) { transcription in
                        fileTranscriptionRow(transcription)
                        Divider().padding(.horizontal)
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Actions

    private func saveAsMarkdown(text: String, fileName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.text]
        let stem = (fileName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(stem.isEmpty ? "transcription" : stem).md"
        panel.title = "Save Transcription"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let markdown = "# Transcription\n\n**Date:** \(formatter.string(from: Date()))\n\n\(text)"
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSSound.beep()
        }
    }

    private func formatDurationLong(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .movie]

        if panel.runModal() == .OK {
            let urls = panel.urls
            if urls.count == 1 {
                // Single file: show selection UI for settings
                selectedAudioURL = urls.first
                isAudioFileSelected = true
            } else if urls.count > 1 {
                // Multiple files: enqueue directly with current settings
                transcriptionManager.enqueueFiles(
                    urls: urls,
                    modelContext: modelContext,
                    engine: engine,
                    languageHint: selectedLanguage,
                    isEnhancementEnabled: enhancementService.isEnhancementEnabled,
                    selectedPromptId: enhancementService.selectedPromptId
                )
            }
        }
    }

    private func handleDroppedFiles(_ providers: [NSItemProvider]) {
        var collectedURLs: [URL] = []
        let group = DispatchGroup()

        let typeIdentifiers = [
            UTType.fileURL.identifier,
            UTType.audio.identifier,
            UTType.movie.identifier,
            UTType.data.identifier,
            "public.file-url"
        ]

        for provider in providers {
            group.enter()
            var handled = false

            for typeIdentifier in typeIdentifiers {
                guard !handled, provider.hasItemConformingToTypeIdentifier(typeIdentifier) else { continue }
                handled = true

                provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                    defer { group.leave() }
                    guard error == nil else { return }

                    var fileURL: URL?
                    if let url = item as? URL {
                        fileURL = url
                    } else if let data = item as? Data {
                        if let url = URL(dataRepresentation: data, relativeTo: nil) {
                            fileURL = url
                        } else if let urlString = String(data: data, encoding: .utf8),
                                  let url = URL(string: urlString) {
                            fileURL = url
                        }
                    } else if let urlString = item as? String {
                        fileURL = URL(string: urlString)
                    }

                    if let url = fileURL,
                       FileManager.default.fileExists(atPath: url.path),
                       SupportedMedia.isSupported(url: url) {
                        DispatchQueue.main.async {
                            collectedURLs.append(url)
                        }
                    }
                }
            }

            if !handled {
                group.leave()
            }
        }

        group.notify(queue: .main) {
            guard !collectedURLs.isEmpty else { return }

            if collectedURLs.count == 1 && !self.transcriptionManager.isProcessing {
                // Single file drop: show selection UI
                self.selectedAudioURL = collectedURLs.first
                self.isAudioFileSelected = true
            } else {
                // Multiple files or already processing: enqueue directly
                self.transcriptionManager.enqueueFiles(
                    urls: collectedURLs,
                    modelContext: self.modelContext,
                    engine: self.engine,
                    languageHint: self.selectedLanguage,
                    isEnhancementEnabled: self.enhancementService.isEnhancementEnabled,
                    selectedPromptId: self.enhancementService.selectedPromptId
                )
                // Clear any existing selection
                self.selectedAudioURL = nil
                self.isAudioFileSelected = false
            }
        }
    }

    private func validateAndSetAudioFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard SupportedMedia.isSupported(url: url) else { return }

        selectedAudioURL = url
        isAudioFileSelected = true
    }
}
