import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AVFoundation

struct AudioTranscribeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var engine: VoiceSEngine
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @StateObject private var transcriptionManager = AudioTranscriptionManager.shared
    @State private var isDropTargeted = false
    @State private var selectedAudioURL: URL?
    @State private var isAudioFileSelected = false
    @State private var isEnhancementEnabled = false
    @State private var selectedPromptId: UUID?
    @AppStorage("TranscribeAudioLanguage") private var selectedLanguage: String = "auto"

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
                
                // Show current transcription result
                if let transcription = transcriptionManager.currentTranscription {
                    VStack(alignment: .leading, spacing: 8) {
                        TranscriptionResultView(transcription: transcription)

                        if let markdown = transcriptionManager.currentTranscriptionMarkdown, !markdown.isEmpty {
                            HStack {
                                Spacer()
                                MarkdownDownloadButton(
                                    markdown: markdown,
                                    sourceFileName: URL(string: transcription.audioFileURL ?? "")?.lastPathComponent
                                )
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                        }
                    }
                }
            }
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

                    // Action Buttons in a row
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
                            selectedAudioURL = nil
                            isAudioFileSelected = false
                        }
                        .buttonStyle(.bordered)
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
        let phaseMessage = transcriptionManager.processingPhase.message

        return VStack(alignment: .leading, spacing: 16) {
            Text(phaseMessage.isEmpty ? "Working…" : phaseMessage)
                .font(.headline)

            if let percent = progress.progressPercent {
                ProgressView(value: percent, total: 100)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            HStack(spacing: 12) {
                if let chunkLabel = progress.chunkLabel {
                    Label("Chunk \(chunkLabel)", systemImage: "square.grid.2x2")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if let percent = progress.progressPercent {
                    Text(String(format: "%.0f%%", percent))
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                if let language = progress.detectedLanguage, !language.isEmpty {
                    Label(language, systemImage: "globe")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    transcriptionManager.cancelProcessing()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !progress.message.isEmpty {
                Text(progress.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(20)
        .frame(maxWidth: 560)
        .background(CardBackground(isSelected: false))
        .padding()
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

/// Writes the raw Markdown produced by the long-audio transcription flow to a user-chosen
/// file. Separate from `AnimatedSaveButton` because that one re-wraps plain text in a
/// `# Transcription` header; long-audio Markdown already has its own header from either
/// the server or `ClientChunkingStrategy.buildMarkdown`.
private struct MarkdownDownloadButton: View {
    let markdown: String
    let sourceFileName: String?

    @State private var isSaved: Bool = false

    var body: some View {
        Button(action: save) {
            HStack(spacing: 6) {
                Image(systemName: isSaved ? "checkmark" : "arrow.down.doc")
                Text(isSaved ? "Downloaded" : "Download Markdown")
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSaved ? Color.green.opacity(0.85) : Color.accentColor)
            )
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSaved)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.text]
        panel.nameFieldStringValue = "\(defaultFileName()).md"
        panel.title = "Save Transcription"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            withAnimation { isSaved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation { isSaved = false }
            }
        } catch {
            NSSound.beep()
        }
    }

    private func defaultFileName() -> String {
        if let source = sourceFileName, !source.isEmpty {
            let stem = (source as NSString).deletingPathExtension
            if !stem.isEmpty { return stem }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "transcription-\(formatter.string(from: Date()))"
    }
}
