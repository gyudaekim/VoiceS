//
//  VoiceSTests.swift
//  VoiceSTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Foundation
import Testing
@testable import VoiceS

struct VoiceSTests {
    @Test func promptDetectionUsesSnapshotPrompts() async throws {
        let rewritePrompt = CustomPrompt(
            id: UUID(),
            title: "Rewrite",
            promptText: "Rewrite the text",
            triggerWords: ["rewrite"]
        )
        let snapshot = EnhancementContextSnapshot(
            isEnabled: false,
            selectedPromptId: nil,
            prompts: [rewritePrompt],
            useClipboardContext: false,
            useScreenCaptureContext: false,
            capturedClipboardText: nil,
            capturedScreenText: nil
        )

        let service = PromptDetectionService()
        let result = service.analyzeText("rewrite hello world", promptSnapshot: snapshot)

        #expect(result.shouldEnableAI)
        #expect(result.selectedPromptId == rewritePrompt.id)
        #expect(result.processedText == "Hello world")
        #expect(result.originalEnhancementState == false)
    }

    @Test func promptDetectionFallsBackWhenNoTriggerExists() async throws {
        let defaultPrompt = CustomPrompt(
            id: UUID(),
            title: "Default",
            promptText: "Default prompt"
        )
        let snapshot = EnhancementContextSnapshot(
            isEnabled: true,
            selectedPromptId: defaultPrompt.id,
            prompts: [defaultPrompt],
            useClipboardContext: true,
            useScreenCaptureContext: true,
            capturedClipboardText: "clipboard",
            capturedScreenText: "screen"
        )

        let service = PromptDetectionService()
        let result = service.analyzeText("plain transcript", promptSnapshot: snapshot)

        #expect(result.shouldEnableAI == false)
        #expect(result.selectedPromptId == nil)
        #expect(result.processedText == "plain transcript")
        #expect(result.originalEnhancementState == true)
        #expect(result.originalPromptId == defaultPrompt.id)
    }

    @Test func backgroundOverlayDefaultsToTranscribingWhileQueueIsActive() async throws {
        let mode = BackgroundProcessingOverlayMode(
            backgroundState: .idle,
            isBackgroundProcessing: true
        )

        #expect(mode == .transcribing)
    }

    @Test func backgroundOverlayUsesEnhancingWhenEnhancementIsRunning() async throws {
        let mode = BackgroundProcessingOverlayMode(
            backgroundState: .enhancing,
            isBackgroundProcessing: true
        )

        #expect(mode == .enhancing)
    }
}
