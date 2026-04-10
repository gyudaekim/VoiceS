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

    // Simulated per-chunk progress: animated from 0→~95% when a chunk starts,
    // resets when the next chunk begins. Gives visual feedback even when real
    // intra-chunk data is unavailable or too coarse (server polls every 2.5s).
    @State private var simulatedChunkPercent: Double = 0
    @State private var lastSeenChunk: Int = 0

    // Ordered language hints matching the gdk-server Qwen ASR web UI dropdown.
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
    
    var body: some View {
        ZStack {
            Color(NSColor.controlBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if transcriptionManager.isProcessing {
                    processingView
                } else {
                    dropZoneView
                }

                Divider()
                    .padding(.vertical)

                // Recent file transcription history
                fileTranscriptionHistorySection
            }
        }
        .sheet(isPresented: $showFullHistory) {
            fileTranscriptionFullHistorySheet
        }
        .onDrop(of: [.fileURL, .data, .audio, .movie], isTargeted: $isDropTargeted) { providers in
            if !transcriptionManager.isProcessing && !isAudioFileSelected {
                handleDroppedFile(providers)
                return true
            }
            return false
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
        .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
            // Drive simulated per-chunk progress: fast start, asymptotic approach to 95%.
            guard transcriptionManager.longAudioProgress.status == .running else {
                if simulatedChunkPercent != 0 { simulatedChunkPercent = 0 }
                return
            }
            let current = transcriptionManager.longAudioProgress.currentChunk ?? 0
            if current != lastSeenChunk {
                lastSeenChunk = current
                simulatedChunkPercent = 0
            }
            let remaining = 95.0 - simulatedChunkPercent
            simulatedChunkPercent += remaining * 0.08
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFileForTranscription)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                // Do not auto-start; only select file for manual transcription
                validateAndSetAudioFile(url)
            }
        }
    }
    
    private var dropZoneView: some View {
        VStack(spacing: 16) {
            if isAudioFileSelected {
                VStack(spacing: 16) {
                    Text("Audio file selected: \(selectedAudioURL?.lastPathComponent ?? "")")
                        .font(.headline)
                    
                    // AI Enhancement Settings
                    VStack(spacing: 16) {
                            // AI Enhancement and Prompt in the same row
                            HStack(spacing: 16) {
                                Toggle("AI Enhancement", isOn: $isEnhancementEnabled)
                                    .toggleStyle(.switch)
                                    .onChange(of: isEnhancementEnabled) { oldValue, newValue in
                                        enhancementService.isEnhancementEnabled = newValue
                                    }
                                
                                if isEnhancementEnabled {
                                    Divider()
                                        .frame(height: 20)
                                    
                                    // Prompt Selection
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
                            // Initialize local state from enhancement service
                            isEnhancementEnabled = enhancementService.isEnhancementEnabled
                            selectedPromptId = enhancementService.selectedPromptId
                        }

                    // Language hint picker — overrides the global SelectedLanguage for this run only.
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
                                    languageHint: selectedLanguage
                                )
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
                        
                        Text("Drop audio or video file here")
                            .font(.headline)
                        
                        Text("or")
                            .foregroundColor(.secondary)
                        
                        Button("Choose File") {
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
    
    private var processingView: some View {
        let progress = transcriptionManager.longAudioProgress
        let phase = transcriptionManager.processingPhase

        return VStack(alignment: .leading, spacing: 16) {
            // Phase header
            Text(phase.message.isEmpty ? "Working…" : phase.message)
                .font(.headline)

            switch progress.status {
            case .uploading:
                // ── Phase 1: Upload ──
                uploadProgressSection(progress: progress)

            case .running, .queued:
                // ── Phase 2: Transcribing ──
                transcribingProgressSection(progress: progress)

            default:
                // Loading / idle / other — indeterminate
                ProgressView()
                    .progressViewStyle(.linear)
            }

            // Bottom row: metadata + cancel
            HStack(spacing: 12) {
                if let language = progress.detectedLanguage, !language.isEmpty {
                    Label(language, systemImage: "globe")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if !progress.message.isEmpty {
                    Text(progress.message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") {
                    transcriptionManager.cancelProcessing()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(20)
        .frame(maxWidth: 560)
        .background(CardBackground(isSelected: false))
        .padding()
    }

    // MARK: - Phase 1: Upload progress

    private func uploadProgressSection(progress: LongAudioProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Upload")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let percent = progress.progressPercent {
                    Text(String(format: "%.0f%%", percent))
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            if let percent = progress.progressPercent {
                ProgressView(value: percent, total: 100)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
    }

    // MARK: - Phase 2: Transcribing progress (per-chunk + overall)

    private func transcribingProgressSection(progress: LongAudioProgress) -> some View {
        let totalChunks = progress.totalChunks ?? 0
        let currentChunk = progress.currentChunk ?? 0
        // Overall = completed chunks / total. Use progressPercent from server if available
        // (more accurate), otherwise compute from chunk count.
        let overallPercent: Double = {
            if let serverPercent = progress.progressPercent, serverPercent > 0 {
                return serverPercent
            }
            return totalChunks > 0 ? Double(currentChunk) / Double(totalChunks) * 100.0 : 0
        }()

        return VStack(alignment: .leading, spacing: 12) {
            // Per-chunk bar — uses simulated progress (timer-driven asymptotic animation)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Chunk \(currentChunk > 0 ? "\(currentChunk)" : "–") / \(totalChunks > 0 ? "\(totalChunks)" : "–")")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(String(format: "%.0f%%", simulatedChunkPercent))
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                ProgressView(value: simulatedChunkPercent, total: 100)
                    .progressViewStyle(.linear)
                    .tint(.orange)
                    .animation(.linear(duration: 0.3), value: simulatedChunkPercent)
            }

            // Overall bar — real data from chunk count or server progress
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Overall")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(String(format: "%.0f%%", overallPercent))
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                ProgressView(value: overallPercent, total: 100)
                    .progressViewStyle(.linear)
            }
        }
    }
    
    // MARK: - File Transcription History

    private var fileTranscriptionHistorySection: some View {
        Group {
            if fileTranscriptions.isEmpty {
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Recent Transcriptions")
                        .font(.headline)
                        .padding(.horizontal)
                        .padding(.bottom, 8)

                    ForEach(fileTranscriptions.prefix(5)) { transcription in
                        fileTranscriptionRow(transcription)
                        if transcription.id != fileTranscriptions.prefix(5).last?.id {
                            Divider().padding(.horizontal)
                        }
                    }

                    if fileTranscriptions.count > 5 {
                        Button {
                            showFullHistory = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("View More (\(fileTranscriptions.count) total)")
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

        return HStack(spacing: 10) {
            Image(systemName: "doc.richtext")
                .foregroundColor(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text(formatDurationLong(transcription.duration))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(transcription.timestamp, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Status indicator
            if transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            } else if transcription.transcriptionStatus == TranscriptionStatus.failed.rawValue {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }

            // Copy button
            Button {
                ClipboardManager.copyToClipboard(bestText)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Copy transcription text")

            // Save as Markdown button
            Button {
                saveAsMarkdown(text: bestText, fileName: displayName)
            } label: {
                Image(systemName: "arrow.down.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Save as Markdown")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
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
                    ForEach(fileTranscriptions) { transcription in
                        fileTranscriptionRow(transcription)
                        Divider().padding(.horizontal)
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

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
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .audio, .movie
        ]
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                selectedAudioURL = url
                isAudioFileSelected = true
            }
        }
    }
    
    private func handleDroppedFile(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        
        // List of type identifiers to try
        let typeIdentifiers = [
            UTType.fileURL.identifier,
            UTType.audio.identifier,
            UTType.movie.identifier,
            UTType.data.identifier,
            "public.file-url"
        ]
        
        // Try each type identifier
        for typeIdentifier in typeIdentifiers {
            if provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
                provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { (item, error) in
                    if let error = error {
                        print("Error loading dropped file with type \(typeIdentifier): \(error)")
                        return
                    }
                    
                    var fileURL: URL?
                    
                    if let url = item as? URL {
                        fileURL = url
                    } else if let data = item as? Data {
                        // Try to create URL from data
                        if let url = URL(dataRepresentation: data, relativeTo: nil) {
                            fileURL = url
                        } else if let urlString = String(data: data, encoding: .utf8),
                                  let url = URL(string: urlString) {
                            fileURL = url
                        }
                    } else if let urlString = item as? String {
                        fileURL = URL(string: urlString)
                    }
                    
                    if let finalURL = fileURL {
                        DispatchQueue.main.async {
                            self.validateAndSetAudioFile(finalURL)
                        }
                        return
                    }
                }
                break // Stop trying other types once we find a compatible one
            }
        }
    }
    
    private func validateAndSetAudioFile(_ url: URL) {
        print("Attempting to validate file: \(url.path)")
        
        // Check if file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("File does not exist at path: \(url.path)")
            return
        }
        
        // Try to access security scoped resource
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        // Validate file type
        guard SupportedMedia.isSupported(url: url) else { return }
        
        print("File validated successfully: \(url.lastPathComponent)")
        selectedAudioURL = url
        isAudioFileSelected = true
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

