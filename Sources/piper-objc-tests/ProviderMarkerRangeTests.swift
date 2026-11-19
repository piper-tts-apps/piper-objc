import Foundation
import Testing
@testable import piper_objc
@testable import piper_utils

@Suite("Provider marker source ranges")
struct ProviderMarkerRangeTests {
    static let reported = "In some respects, it feels like Motorola's design process was simply to take every fancy component it could get its hands on and shove it in the Signature 27."
    static let control = "The phone features a big 6.8-inch Extreme AMOLED Duo display, which is based on the same tandem OLED tech Apple used in the new ProLED MacBook Pro. Unsurprisingly, it looks awesome."

    private func wordMarkers(_ xml: String, aligned: Bool) throws -> [PiperSpeechMarker] {
        var nodes: [SSMLNode] = []
        SSMLParser().parse(ssml: xml) { nodes.append($0) }
        let groups = aligned ? PiperAlignmentParser.group(phonemes: [97, 0, 98, 0], ids: [5, 6], alignments: [8, 16]) : []
        var result: [PiperSpeechMarker] = []
        var startByte = 12
        for node in nodes {
            var cursor = 0
            for sentence in PiperSentencesExtractor.extract(from: node.text) {
                let source = try #require(node.locateChunk(sentence, from: &cursor))
                let markers = PiperSpeechMarker.markers(for: sentence, source: source, startByteOffset: startByte,
                                                       totalBytes: 1024, groups: groups)
                let local = NSRange(location: 0, length: sentence.utf16.count)
                let timing = aligned
                    ? PiperSpeechMarker.generateMarkersWithAlignment(for: sentence, sentenceNSRange: local,
                                                                     startByteOffset: startByte, groups: groups)
                    : PiperSpeechMarker.generateMarkers(for: sentence, sentenceNSRange: local,
                                                        startByteOffset: startByte, totalBytes: 1024)
                #expect(markers.map(\.byteOffset) == timing.map(\.byteOffset))
                #expect(markers.first?.range == source.sourceRange)
                result += markers.filter { $0.type == .word }
                startByte += 1024
            }
        }
        return result
    }

    static func checkRanges(_ markers: [PiperSpeechMarker], _ expected: [String], in xml: String,
                            after start: Int) throws {
        let raw = xml as NSString
        var end = start
        try #require(markers.count == expected.count)
        for (marker, word) in zip(markers, expected) {
            let range = raw.range(of: word, options: .literal, range: NSRange(location: end, length: raw.length - end))
            try #require(range.location != NSNotFound)
            #expect(marker.range == range)
            end = NSMaxRange(range)
        }
    }

    @Test(arguments: ["'", "&apos;", "&#39;", "&#x27;"], [true, false])
    func reportedSentence(apostrophe: String, aligned: Bool) throws {
        let escaped = Self.reported.replacingOccurrences(of: "'", with: apostrophe)
        for prefix in ["<speak>", "<speak><prosody rate=\"100%\">",
                       "<speak version=\"1.0\" xml:lang=\"en-US\"><prosody rate=\"100.0%\" volume=\"0dB\">"] {
            let xml = prefix + escaped + (prefix.hasSuffix("<speak>") ? "</speak>" : "</prosody></speak>")
            let words = escaped.split(separator: " ").map {
                aligned ? String($0).trimmingCharacters(in: CharacterSet(charactersIn: ",.")) : String($0)
            }
            try Self.checkRanges(wordMarkers(xml, aligned: aligned), words, in: xml, after: prefix.utf16.count)
        }
    }

    @Test(arguments: [true, false])
    func workingControl(aligned: Bool) throws {
        let xml = "<speak>" + Self.control + "</speak>"
        let markers = try wordMarkers(xml, aligned: aligned)
        var words = Self.control.split(separator: " ").map(String.init)
        // NaturalLanguage and the Linux fallback may split the decimal differently.
        if markers.count == words.count + 1, let i = words.firstIndex(of: "6.8-inch") {
            words.replaceSubrange(i...i, with: ["6.", "8-inch"])
        }
        if aligned { words = words.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.")) } }
        try Self.checkRanges(markers, words, in: xml, after: 7)
    }

    @Test(arguments: [true, false])
    func sourceSpellingAndWhitespace(aligned: Bool) throws {
        let prefix = "<?xml version='1.0'?>\n<speak hint='go > go'>"
        let xml = prefix + "👩🏽‍💻  Cafe\u{301} &#x1F642; go\r\n  go <prosody>R&amp;D</prosody> go</speak>"
        try Self.checkRanges(wordMarkers(xml, aligned: aligned),
                             ["👩🏽‍💻", "Cafe\u{301}", "&#x1F642;", "go", "go", "R&amp;D", "go"],
                             in: xml, after: prefix.utf16.count)
        var nodes: [SSMLNode] = []
        SSMLParser().parse(ssml: xml) { nodes.append($0) }
        let first = try #require(nodes.first)
        #expect(first.text.utf8.elementsEqual(first.text.precomposedStringWithCanonicalMapping.utf8))
    }

    @Test func commentsAndRepeatedText() throws {
        let prefix = "<speak hint='repeat'>"
        let xml = prefix + "re<!-- repeat > -->peat <voice>repeat</voice> <?test ignored?>repeat</speak>"
        let markers = try wordMarkers(xml, aligned: true)
        try Self.checkRanges(markers, ["re<!-- repeat > -->peat", "repeat", "repeat"], in: xml, after: prefix.utf16.count)
    }
    @Test func escapedCharactersAndEmptyElements() throws {
        let prefix = "<speak xml:lang='en-US'>"
        let words = ["e&#x301;", "&quot;quote&quot;", "&lt;x&gt;", "again", "again"]
        let xml = prefix + words[0] + " " + words[1] + " " + words[2]
                         + " <break/>" + words[3] + "<break time='2ms'/> " + words[4] + "</speak>"
        try Self.checkRanges(wordMarkers(xml, aligned: false), words, in: xml, after: prefix.utf16.count)
    }

    @Test func unindexedEntityDoesNotDisplaceNextElement() throws {
        let xml = "<!DOCTYPE speak [<!ENTITY vendor 'tool'>]><speak><p>first &vendor;</p><p>after</p></speak>"
        var nodes: [SSMLNode] = []
        SSMLParser().parse(ssml: xml) { nodes.append($0) }
        let last = try #require(nodes.last)
        #expect(last.text == "after")
        #expect(last.ssmlRange == (xml as NSString).range(of: "after"))
        if let first = nodes.first, first.text.hasPrefix("first") {
            #expect(first.ssmlRange.location == NSNotFound)
        }
    }

    @Test func plainTextKeepsUTF16Base() throws {
        let text = "🙂 repeat  repeat"
        let node = SSMLNode(text: text, lengthScale: 1, ssmlRange: NSRange(location: 20, length: text.utf16.count))
        var cursor = 0
        var chunk = try #require(node.locateChunk("🙂 repeat repeat", from: &cursor))
        #expect(chunk.sourceRange == node.ssmlRange)
        #expect(chunk.wordRange(for: NSRange(location: 0, length: 2)) == NSRange(location: 20, length: 2))
        #expect(chunk.wordRange(for: NSRange(location: 3, length: 6)) == NSRange(location: 23, length: 6))
        #expect(chunk.wordRange(for: NSRange(location: 10, length: 6)) == NSRange(location: 31, length: 6))
        #expect(chunk.wordRange(for: NSRange(location: NSNotFound, length: 1)) == nil)
    }

}
