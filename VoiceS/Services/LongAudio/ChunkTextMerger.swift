import Foundation

/// Merges per-chunk transcription results into a single text, attempting to remove the
/// duplicated text that appears in overlap regions between adjacent chunks.
///
/// Strategy: for each adjacent pair, find the longest suffix of the running result that
/// matches a prefix of the next chunk (case-insensitive, character-level). Drop that
/// prefix from the next chunk before appending. If no acceptable overlap is found, append
/// with a space separator — the transcript will contain slight duplication near the seam,
/// which is acceptable as a fallback.
enum ChunkTextMerger {
    /// Minimum number of matching characters required to count as an overlap match.
    /// Too small and we risk random word matches; too large and short overlaps are missed.
    static let minMatchChars = 10

    /// Maximum characters to scan from each side when looking for overlap.
    /// 256 chars is comfortably more than ~20 words (the expected overlap for a 2 s window).
    static let maxScanChars = 256

    static func merge(chunkTexts: [String]) -> String {
        let trimmed = chunkTexts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !trimmed.isEmpty else { return "" }

        var result = trimmed[0]

        for next in trimmed.dropFirst() where !next.isEmpty {
            if result.isEmpty {
                result = next
                continue
            }

            let overlapLen = longestSuffixPrefixMatch(suffixOf: result, prefixOf: next)

            if overlapLen >= minMatchChars {
                let remainder = next.dropFirst(overlapLen)
                let trimmedRemainder = String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedRemainder.isEmpty {
                    if needsSeparator(between: result, and: trimmedRemainder) {
                        result += " "
                    }
                    result += trimmedRemainder
                }
            } else {
                // No confident overlap — append with a separator and accept minor duplication.
                if needsSeparator(between: result, and: next) {
                    result += " "
                }
                result += next
            }
        }

        return result
    }

    /// Returns the length of the longest case-insensitive character-level match between
    /// the tail of `suffixOf` and the head of `prefixOf`, up to `maxScanChars`. Returns 0
    /// if no match is found that meets `minMatchChars`.
    ///
    /// Performance: converts to lowercased char arrays once and slices them — avoids
    /// per-iteration allocations in the comparison loop.
    static func longestSuffixPrefixMatch(suffixOf left: String, prefixOf right: String) -> Int {
        // Pre-allocate once outside the comparison loop to avoid repeated allocations.
        let leftChars = Array(left.suffix(maxScanChars).lowercased())
        let rightChars = Array(right.prefix(maxScanChars).lowercased())

        let maxLen = min(leftChars.count, rightChars.count)
        if maxLen < minMatchChars { return 0 }

        // Walk from longest possible overlap down to minMatchChars; return first hit.
        var k = maxLen
        while k >= minMatchChars {
            let leftTail = leftChars.suffix(k)
            let rightHead = rightChars.prefix(k)
            if leftTail.elementsEqual(rightHead) {
                return k
            }
            k -= 1
        }
        return 0
    }

    private static func needsSeparator(between left: String, and right: String) -> Bool {
        guard let lastChar = left.last, let firstChar = right.first else { return false }
        if lastChar.isWhitespace || firstChar.isWhitespace { return false }
        // Avoid adding a space after punctuation that already ends a sentence cleanly.
        return true
    }
}
