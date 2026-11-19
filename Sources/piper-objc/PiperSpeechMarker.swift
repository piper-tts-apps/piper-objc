import Foundation
#if canImport(piper_utils)
import piper_utils
#endif

@objc public enum PiperSpeechMarkerType: Int {
    public typealias RawValue = Int
    case sentence
    case word
}

@objc public class PiperSpeechMarker: NSObject {
    public let range: NSRange
    public let byteOffset: Int
    public let type: PiperSpeechMarkerType
    
    public init(range: NSRange, byteOffset: Int, type: PiperSpeechMarkerType = .sentence) {
        self.range = range
        self.byteOffset = byteOffset
        self.type = type
        super.init()
    }
    
    /// Legacy heuristic – estimate word byte offsets by character proportion.
    /// Retained for fallback when alignment data unavailable (e.g., file synthesis path).
    /// - Parameters:
    ///   - sentence: The text of the sentence.
    ///   - sentenceNSRange: The range of the sentence within the original, full text.
    ///   - startByteOffset: The starting byte offset for this sentence's audio data.
    ///   - totalBytes: The total number of bytes for the synthesized sentence audio.
    /// - Returns: An array of `PiperSpeechMarker` objects.
    public static func generateMarkers(for sentence: String, sentenceNSRange: NSRange, startByteOffset: Int, totalBytes: Int) -> [PiperSpeechMarker] {
        let words = sentence.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !words.isEmpty, totalBytes > 0, sentenceNSRange.location != NSNotFound else {
            return [PiperSpeechMarker(range: sentenceNSRange, byteOffset: startByteOffset, type: .sentence)]
        }

        let totalCharacters = words.joined().count
        guard totalCharacters > 0 else {
            return [PiperSpeechMarker(range: sentenceNSRange, byteOffset: startByteOffset, type: .sentence)]
        }

        var markers: [PiperSpeechMarker] = []
        // Add a marker for the entire sentence first.
        markers.append(PiperSpeechMarker(range: sentenceNSRange, byteOffset: startByteOffset, type: .sentence))

        var currentByteOffset = startByteOffset
        var currentSearchIndexInSentence = sentence.startIndex

        for word in words {
            guard let wordRangeInSentence = sentence.range(of: word, options: .literal, range: currentSearchIndexInSentence..<sentence.endIndex) else {
                continue
            }
            
            let local = NSRange(wordRangeInSentence, in: sentence)
            let wordNSRange = NSRange(location: sentenceNSRange.location + local.location, length: local.length)
            let wordBytes = Int(Double(totalBytes) * (Double(word.count) / Double(totalCharacters)))
            markers.append(PiperSpeechMarker(range: wordNSRange, byteOffset: currentByteOffset, type: .word))
            currentByteOffset += wordBytes
            currentSearchIndexInSentence = wordRangeInSentence.upperBound
        }
        return markers
    }

    // MARK: - Alignment-aware generation (TDD target)

    /**
     Alignment-based marker generation.

     Uses per-phoneme sample counts from `piper_audio_chunk.alignments` (grouped by the piper.h rule)
     to derive accurate byte offsets.

     Grouping rule from piper.h (verbatim):
     > Phonemes will look like [p1, p1, 0, p2, p2, 0, ...] where the same phoneme codepoint is
     > repeated for each id from that phoneme (usually just one id plus pad).
     > Groups are separated by a 0. Read N codepoints until 0, next N ids & N alignments belong to that phoneme.

     BOS=1, PAD=0, EOS=2 groups are ignored for highlighting but their sample counts still advance the cumulative offset.

     - Parameters:
        - sentence: original sentence text
        - sentenceNSRange: NSRange of sentence inside SSML
        - startByteOffset: bytes already generated before this sentence
        - groups: parsed phoneme groups (including specials)
        - sampleRate: not used for byte calc today but kept for future resample compensation

     - Returns: [sentence marker] + word markers with accurate offsets.

     Punctuation fix #31: word tokens like “‘idealists’.” are stripped of surrounding punctuation for range search,
     so that highlighting still covers inner “idealists”.
     */
    public static func generateMarkersWithAlignment(
        for sentence: String,
        sentenceNSRange: NSRange,
        startByteOffset: Int,
        groups: [PiperAlignmentParser.PhonemeGroup]
    ) -> [PiperSpeechMarker] {
        guard sentenceNSRange.location != NSNotFound else {
            return [PiperSpeechMarker(range: sentenceNSRange, byteOffset: startByteOffset, type: .sentence)]
        }

        let sentenceMarker = PiperSpeechMarker(range: sentenceNSRange, byteOffset: startByteOffset, type: .sentence)

        // Split by whitespace but keep tokens for search
        let rawTokens = sentence.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if rawTokens.isEmpty {
            return [sentenceMarker]
        }

        // Total samples from all groups (including specials) – matches real audio duration roughly
        let totalSamplesFromGroups = groups.reduce(0) { $0 + $1.sampleCount }
        // If no alignment data, fallback to legacy byte heuristic (but we have no totalBytes). Use sentence length fallback.
        guard totalSamplesFromGroups > 0 else {
            // Fallback: estimate totalBytes from sentence? Use legacy path with estimated bytes = 0? Return sentence only + heuristic words
            // Use legacy with totalBytes = rawTokens.joined().count * 100 * 4 as dummy? Better return sentence marker only to avoid mis-timing,
            // but we still generate word markers via char proportion using totalSamples*4 as totalBytes for monotonicity.
            let totalBytesFallback = max(1, rawTokens.joined().count * 200)
            return generateMarkers(for: sentence, sentenceNSRange: sentenceNSRange, startByteOffset: startByteOffset, totalBytes: totalBytesFallback)
        }

        // Filtered groups (non-special) for actual word timing
        let realGroups = groups.filter { !$0.isSpecial }
        // If all groups filtered (edge empty), fallback
        if realGroups.isEmpty {
            // Still use specials total for totalBytes estimation
            let totalBytes = totalSamplesFromGroups * MemoryLayout<Float>.size
            return generateMarkers(for: sentence, sentenceNSRange: sentenceNSRange, startByteOffset: startByteOffset, totalBytes: totalBytes)
        }

        // Map phoneme groups to words – proportional to stripped core word character count
        // Core word stripping for #31: trim surrounding punctuation including curly quotes U+2018/U+2019, straight quotes, .,;:!?()[]{}—–
        let punctuationTrimSet = CharacterSet(charactersIn: "‘’'\".,;:!?()[]{}—–")
        var coreWords: [String] = []
        var tokenRanges: [(original: String, core: String)] = []
        for tok in rawTokens {
            let core = tok.trimmingCharacters(in: punctuationTrimSet)
            // If core empty (token was pure punctuation), skip token but keep original for range? Treat as punctuation pause – skip marker
            if core.isEmpty {
                continue
            }
            coreWords.append(core)
            tokenRanges.append((tok, core))
        }

        if coreWords.isEmpty {
            return [sentenceMarker]
        }

        let totalCoreChars = coreWords.joined().count
        guard totalCoreChars > 0 else { return [sentenceMarker] }

        // Distribute phoneme groups across core words proportionally
        // Example: 20 groups, first word 5 chars of 20 total -> 5 groups
        var groupIdx = 0
        var markers: [PiperSpeechMarker] = [sentenceMarker]

        var currentSearchStart = sentence.startIndex
        var cumulativeSamples = 0
        // Include initial BOS silence offset: first real group's cumulativeOffsetBefore includes BOS samples
        if let firstReal = realGroups.first {
            cumulativeSamples = firstReal.cumulativeOffsetBefore
        }

        for (i, pair) in tokenRanges.enumerated() {
            let core = pair.core
            // Find core range in sentence starting from currentSearchStart
            // First try to find original token (which includes punctuation), then inside it find core.
            // Simplified: search for core directly – more robust for "‘idealists’." case.
            guard let coreRangeInSentence = sentence.range(of: core, options: .literal, range: currentSearchStart..<sentence.endIndex) else {
                continue
            }
            let local = NSRange(coreRangeInSentence, in: sentence)
            let wordNSRange = NSRange(location: sentenceNSRange.location + local.location, length: local.length)

            // How many phoneme groups belong to this word?
            // Proportional distribution, ensures sum = realGroups.count
            let groupsForWord: Int
            if i == tokenRanges.count - 1 {
                groupsForWord = realGroups.count - groupIdx
            } else {
                let proportion = Double(core.count) / Double(totalCoreChars)
                groupsForWord = max(1, Int(round(proportion * Double(realGroups.count))))
                // Clamp to remaining
                // Ensure at least 1, but not over remaining- (wordsLeft-1)
            }

            let clampedGroups = min(groupsForWord, realGroups.count - groupIdx)
            // Sum sample counts for this word's groups to advance offset for next word
            var wordSampleCount = 0
            for g in realGroups[groupIdx ..< groupIdx+clampedGroups] {
                wordSampleCount += g.sampleCount
            }

            let byteOffset = startByteOffset + cumulativeSamples * MemoryLayout<Float>.size
            markers.append(PiperSpeechMarker(range: wordNSRange, byteOffset: byteOffset, type: .word))

            cumulativeSamples += wordSampleCount
            groupIdx += clampedGroups
            currentSearchStart = coreRangeInSentence.upperBound

            // Edge: if we consumed all groups early but still have words, give them same offset (overlap) rather than drop
            if groupIdx >= realGroups.count && i < tokenRanges.count - 1 {
                // remaining words get final offset
                // cumulativeSamples already at total
                continue
            }
        }

        // Monotonicity guarantee: byte offsets already increasing because cumulativeSamples only increases

        return markers
    }
}

extension PiperSpeechMarker {
    /// Both timing paths produce offsets in the audio stream and ranges in
    /// chunk-local UTF-16. Convert only the text ranges to provider coordinates.
    static func markers(for sentence: String, source: SSMLChunk, startByteOffset: Int, totalBytes: Int,
                        groups: [PiperAlignmentParser.PhonemeGroup]) -> [PiperSpeechMarker] {
        let local = NSRange(location: 0, length: sentence.utf16.count)
        let markers: [PiperSpeechMarker]
        if groups.isEmpty {
            markers = generateMarkers(for: sentence, sentenceNSRange: local, startByteOffset: startByteOffset,
                                      totalBytes: totalBytes)
        } else {
            markers = generateMarkersWithAlignment(for: sentence, sentenceNSRange: local,
                                                   startByteOffset: startByteOffset, groups: groups)
        }
        var chunk = source
        return markers.compactMap { marker in
            let range = marker.type == .sentence ? chunk.sourceRange : chunk.wordRange(for: marker.range)
            guard let range else { return nil }
            return PiperSpeechMarker(range: range, byteOffset: marker.byteOffset, type: marker.type)
        }
    }
}
