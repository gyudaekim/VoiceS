import Foundation

/// A single chunk of mono 16 kHz audio samples plus its position in the source file.
struct AudioChunk: Equatable {
    let index: Int              // 0-based chunk index
    let startSample: Int        // inclusive
    let endSample: Int          // exclusive
    let samples: [Float]

    var startSeconds: Double { Double(startSample) / AudioChunker.sampleRate }
    var endSeconds: Double { Double(endSample) / AudioChunker.sampleRate }
}

/// Splits a long sample buffer into fixed-size windows with a small overlap so the
/// downstream transcription model can stitch chunk boundaries back together cleanly.
///
/// The gdk-server Qwen ASR server does this silence-aware with VAD cut points; the client
/// keeps things simple with fixed-duration windows. `ChunkTextMerger` handles the overlap
/// dedup on the text side.
enum AudioChunker {
    /// Target sample rate used throughout the app for transcription (matches `AudioProcessor.AudioFormat.targetSampleRate`).
    static let sampleRate: Double = 16_000

    /// Default window length per chunk. 30 s matches Whisper's native context window and
    /// the chunk size the gdk-server uses.
    static let defaultWindowSeconds: Double = 30

    /// Overlap between adjacent chunks. 2 s matches the server's overlap setting.
    static let defaultOverlapSeconds: Double = 2

    /// Splits `samples` into overlapping windows. If the input is shorter than one window,
    /// returns a single chunk containing the whole input.
    static func chunk(
        samples: [Float],
        windowSeconds: Double = defaultWindowSeconds,
        overlapSeconds: Double = defaultOverlapSeconds
    ) -> [AudioChunk] {
        precondition(windowSeconds > overlapSeconds, "window must be longer than overlap")

        let totalSamples = samples.count
        guard totalSamples > 0 else { return [] }

        let windowSamples = Int(windowSeconds * sampleRate)
        let overlapSamples = Int(overlapSeconds * sampleRate)
        let step = windowSamples - overlapSamples     // how far the window advances per chunk

        if totalSamples <= windowSamples {
            return [AudioChunk(index: 0, startSample: 0, endSample: totalSamples, samples: samples)]
        }

        var chunks: [AudioChunk] = []
        var start = 0
        var index = 0

        while start < totalSamples {
            let end = min(start + windowSamples, totalSamples)
            let slice = Array(samples[start..<end])
            chunks.append(AudioChunk(index: index, startSample: start, endSample: end, samples: slice))
            index += 1

            if end == totalSamples { break }
            start += step
        }

        return chunks
    }
}
