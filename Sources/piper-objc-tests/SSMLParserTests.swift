import Foundation
import Testing
@testable import piper_utils

@Suite("SSMLParser Tests")
struct SSMLParserTests {
    @Test("parses plain text")
    func testPlainText() {
        let parser = SSMLParser()
        var nodes: [SSMLNode] = []
        parser.parse(ssml: "Hello world!") { nodes.append($0) }
        #expect(nodes.count == 1)
        #expect(nodes[0].text == "Hello world!")
        #expect(nodes[0].lengthScale == 1.0)
    }
    
    @Test("parses prosody rate percent correctly")
    func testProsodyRatePercent() {
        let parser = SSMLParser()
        var nodes: [SSMLNode] = []
        parser.parse(ssml: "<prosody rate=\"150%\">Fast</prosody>") { nodes.append($0) }
        #expect(nodes.count == 1)
        #expect(nodes[0].text == "Fast")
        #expect(nodes[0].lengthScale == 1.5)
    }

    @Test("handles nested prosody")
    func testNestedProsody() {
        let parser = SSMLParser()
        let ssml = "<prosody rate=\"200%\">Very <prosody rate=\"50%\">slow</prosody> fast</prosody>"
        var nodes: [SSMLNode] = []
        parser.parse(ssml: ssml) { nodes.append($0) }
        #expect(nodes.count == 3)
        // Node 0: "Very", rate=2.0
        #expect(nodes[0].text.trimmingCharacters(in: .whitespacesAndNewlines) == "Very")
        #expect(abs(nodes[0].lengthScale - 2.0) < 0.01)
        // Node 1: "slow", rate=0.5
        #expect(nodes[1].text.trimmingCharacters(in: .whitespacesAndNewlines) == "slow")
        #expect(abs(nodes[1].lengthScale - 0.5) < 0.01)
        // Node 2: " fast", rate=2.0
        #expect(nodes[2].text.trimmingCharacters(in: .whitespacesAndNewlines) == "fast")
        #expect(abs(nodes[2].lengthScale - 2.0) < 0.01)
    }
    
    @Test("handles French prosody inside speak tag")
    func testNestedFrenchProsody() {
        let parser = SSMLParser()
        let ssml = "<speak>L’élève <prosody rate=\"100%\">écoute</prosody> bien.</speak>"
        var nodes: [SSMLNode] = []
        parser.parse(ssml: ssml) { nodes.append($0) }
        #expect(nodes.count == 3)
        // Node 0: "L’élève", rate=1.0
        #expect(nodes[0].text.trimmingCharacters(in: .whitespacesAndNewlines) == "L’élève")
        #expect(abs(nodes[0].lengthScale - 0.5) < 0.01)
        // Node 1: "écoute", rate=0.5
        #expect(nodes[1].text.trimmingCharacters(in: .whitespacesAndNewlines) == "écoute")
        #expect(abs(nodes[1].lengthScale - 1.0) < 0.01)
        // Node 2: " bien.", rate=1.0
        #expect(nodes[2].text.trimmingCharacters(in: .whitespacesAndNewlines) == "bien.")
        #expect(abs(nodes[2].lengthScale - 0.5) < 0.01)
    }

    @Test("returns empty for malformed or empty input")
    func testMalformedAndEmpty() {
        let parser = SSMLParser()
        var n0: [SSMLNode] = []
        parser.parse(ssml: "") { n0.append($0) }
        #expect(n0.isEmpty, "Empty input should produce no nodes")
        var n1: [SSMLNode] = []
        parser.parse(ssml: "<prosody>") { n1.append($0) }
        #expect(n1.count == 1, "Malformed input should be treated as plain text")
        #expect(n1[0].text == "<prosody>", "Malformed node text should be the input string")
        var n2: [SSMLNode] = []
        parser.parse(ssml: "<prosody rate=\"abc\">text</prosody>") { n2.append($0) }
        #expect(n2.count == 1)
        #expect(n2[0].text == "text")
        #expect(n2[0].lengthScale == 0.5)
    }

    @Test("handles XML entities correctly")
    func testXMLEntities() {
        let parser = SSMLParser()
        // &amp; -> &, &lt; -> <, &quot; -> "
        let ssml = "<speak>Fish &amp; Chips are &lt; $10 &quot;Special&quot;</speak>"
        var nodes: [SSMLNode] = []
        parser.parse(ssml: ssml) { nodes.append($0) }
        
        #expect(nodes.count == 1)
        #expect(nodes[0].text == "Fish & Chips are < $10 \"Special\"")
    }

    @Test("ignores XML comments")
    func testXMLComments() {
        let parser = SSMLParser()
        let ssml = "<speak>Visible <!-- This is a comment --> text</speak>"
        var nodes: [SSMLNode] = []
        parser.parse(ssml: ssml) { nodes.append($0) }
        
        #expect(nodes.count == 1)
        // The parser usually leaves the whitespace where the comment was
        #expect(nodes[0].text.contains("Visible"))
        #expect(nodes[0].text.contains("text"))
        #expect(!nodes[0].text.contains("comment"))
    }

    @Test("handles multiple speed changes in sequence")
    func testSequentialProsody() {
        let parser = SSMLParser()
        let ssml = "<speak><prosody rate='50%'>Slow</prosody><prosody rate='200%'>Fast</prosody></speak>"
        var nodes: [SSMLNode] = []
        parser.parse(ssml: ssml) { nodes.append($0) }
        
        #expect(nodes.count == 2)
        #expect(nodes[0].lengthScale == 0.5)
        #expect(nodes[1].lengthScale == 2.0)
    }

    @Test("ignores unsupported tags but preserves inner text")
    func testUnsupportedTags() {
        let parser = SSMLParser()
        let ssml = "<speak><voice name='en_US'>Hello <emphasis>world</emphasis></voice></speak>"
        var nodes: [SSMLNode] = []
        parser.parse(ssml: ssml) { nodes.append($0) }
        
        // Current implementation flushes on every tag start/end.
        // "Hello " is one node, "world" is another.
        #expect(nodes.count >= 2)
        let joined = nodes.map { $0.text }.joined()
        #expect(joined.contains("Hello"))
        #expect(joined.contains("world"))
    }

    @Test("handles text outside of speak tags")
    func testTextOutsideSpeakTag() {
        let parser = SSMLParser()
        let ssml = "Before <speak>Inside</speak> After"
        var nodes: [SSMLNode] = []
        parser.parse(ssml: ssml) { nodes.append($0) }
        
        let allText = nodes.map { $0.text }.joined(separator: " ")
        #expect(allText.contains("Before"))
        #expect(allText.contains("Inside"))
        #expect(allText.contains("After"))
    }

    @Test("parses attribute with single quotes and extra spaces")
    func testAttributeFormattingVariations() {
        let parser = SSMLParser()
        let ssml = "<prosody   rate = ' 50% ' >Slow</prosody>"
        var nodes: [SSMLNode] = []
        parser.parse(ssml: ssml) { nodes.append($0) }
        
        #expect(nodes.count == 1)
        #expect(nodes[0].lengthScale == 0.5)
        #expect(nodes[0].text == "Slow")
    }

    @Test("parses float multiplier rate like 1.0 and 0.5")
    func testFloatMultiplierRates() {
        let parser = SSMLParser()
        var n1: [SSMLNode] = []
        parser.parse(ssml: "<prosody rate=\"1.0\">Normal</prosody>") { n1.append($0) }
        #expect(n1.count == 1)
        #expect(abs(n1[0].lengthScale - 1.0) < 0.001, "1.0 multiplier should be 1.0")

        var n2: [SSMLNode] = []
        parser.parse(ssml: "<prosody rate=\"0.5\">Half</prosody>") { n2.append($0) }
        #expect(n2.count == 1)
        #expect(abs(n2[0].lengthScale - 0.5) < 0.001, "0.5 multiplier should be 0.5")

        var n3: [SSMLNode] = []
        parser.parse(ssml: "<prosody rate=\"2.0\">Double</prosody>") { n3.append($0) }
        #expect(n3.count == 1)
        #expect(abs(n3[0].lengthScale - 2.0) < 0.001, "2.0 multiplier should be 2.0")

        var n4: [SSMLNode] = []
        parser.parse(ssml: "<prosody rate=\"1.5\">Fast</prosody>") { n4.append($0) }
        #expect(n4.count == 1)
        #expect(abs(n4[0].lengthScale - 1.5) < 0.001)
    }

    @Test("plain text fallback returns 1.0 multiplier normal")
    func testPlainTextFallback1x() {
        let parser = SSMLParser()
        var nodes: [SSMLNode] = []
        parser.parse(ssml: "Hello world plain") { nodes.append($0) }
        #expect(nodes.count == 1)
        #expect(nodes[0].lengthScale == 1.0, "Plain text fallback should be 1.0 multiplier normal, not 0.5")
    }

    // MARK: - SSML-lite

    @Test("break time emits a pause node between speech nodes")
    func testBreakTime() {
        let parser = SSMLParser()
        var nodes: [SSMLNode] = []
        parser.parse(ssml: "<speak>One <break time=\"500ms\"/> two</speak>") { nodes.append($0) }
        #expect(nodes.count == 3)
        #expect(nodes[0].kind == .text)
        #expect(nodes[1].kind == .pause)
        #expect(nodes[1].pauseMs == 500)
        #expect(nodes[2].kind == .text)
    }

    @Test("break strength maps to milliseconds")
    func testBreakStrength() {
        let parser = SSMLParser()
        var nodes: [SSMLNode] = []
        parser.parse(ssml: "<speak>A <break strength=\"strong\"/> B</speak>") { nodes.append($0) }
        #expect(nodes.count == 3)
        #expect(nodes[1].kind == .pause)
        #expect(nodes[1].pauseMs == 700)
    }

    @Test("named prosody rates use the multiplier path, not the AV curve")
    func testNamedProsodyRatesMultiplierPath() {
        let parser = SSMLParser()
        var slow: [SSMLNode] = []
        parser.parse(ssml: "<prosody rate=\"slow\">Slow</prosody>") { slow.append($0) }
        #expect(slow.count == 1)
        #expect(slow[0].usesMultiplierPath)
        // Node keeps piper-objc's existing keyword value; getOptions
        // converts it as 1 / 0.75 = 1.333 length_scale.
        #expect(abs(slow[0].lengthScale - 0.75) < 0.01)

        var fast: [SSMLNode] = []
        parser.parse(ssml: "<prosody rate=\"fast\">Fast</prosody>") { fast.append($0) }
        #expect(fast[0].usesMultiplierPath)
        #expect(abs(fast[0].lengthScale - 1.5) < 0.01)

        // Percent rates keep the legacy path, not the multiplier path.
        var percent: [SSMLNode] = []
        parser.parse(ssml: "<prosody rate=\"150%\">Fast</prosody>") { percent.append($0) }
        #expect(!percent[0].usesMultiplierPath)
        #expect(percent[0].lengthScale == 1.5)
    }

    @Test("prosody volume is a post-synthesis gain, not a rate")
    func testProsodyVolume() {
        let parser = SSMLParser()
        var nodes: [SSMLNode] = []
        parser.parse(ssml: "<prosody volume=\"loud\">Loud</prosody>") { nodes.append($0) }
        #expect(nodes.count == 1)
        #expect(abs(nodes[0].volume - 1.4) < 0.01)
        #expect(nodes[0].lengthScale == 0.5, "Volume alone must not change the legacy rate")
    }

    @Test("emphasis is a rate factor on the node")
    func testEmphasis() {
        let parser = SSMLParser()
        var nodes: [SSMLNode] = []
        parser.parse(ssml: "<emphasis level=\"strong\">Important</emphasis>") { nodes.append($0) }
        #expect(nodes.count == 1)
        #expect(abs(nodes[0].emphasisFactor - 0.85) < 0.01)
    }

    @Test("say-as expands dates, times, and telephone numbers")
    func testSayAs() {
        let parser = SSMLParser()
        var date: [SSMLNode] = []
        parser.parse(ssml: "<say-as interpret-as=\"date\">2026-11-02</say-as>") { date.append($0) }
        #expect(date.count == 1)
        #expect(date[0].text == "November second, twenty twenty six")

        var time: [SSMLNode] = []
        parser.parse(ssml: "<say-as interpret-as=\"time\">10:05</say-as>") { time.append($0) }
        #expect(time[0].text == "ten oh five")

        var phone: [SSMLNode] = []
        parser.parse(ssml: "<say-as interpret-as=\"telephone\">555-1234</say-as>") { phone.append($0) }
        #expect(phone[0].text == "five five five one two three four")

        var ordinal: [SSMLNode] = []
        parser.parse(ssml: "<say-as interpret-as=\"ordinal\">3rd</say-as>") { ordinal.append($0) }
        #expect(ordinal[0].text == "third")
    }

    @Test("say-as range points at the original text, not the expansion")
    func testSayAsRange() {
        let parser = SSMLParser()
        let ssml = "<speak><say-as interpret-as=\"date\">2026-11-02</say-as></speak>"
        var nodes: [SSMLNode] = []
        parser.parse(ssml: ssml) { nodes.append($0) }
        #expect(nodes.count == 1)
        #expect(nodes[0].text == "November second, twenty twenty six")
        let range = nodes[0].ssmlRange
        #expect(range.location != 0 || range.length > 0)
        let start = ssml.index(ssml.startIndex, offsetBy: range.location)
        let end = ssml.index(start, offsetBy: range.length)
        #expect(String(ssml[start..<end]) == "2026-11-02")
    }

    @Test("sub alias replaces the inner text, spell spaces letters")
    func testSubAndSpell() {
        let parser = SSMLParser()
        var sub: [SSMLNode] = []
        parser.parse(ssml: "<sub alias=\"Doctor\">Dr.</sub>") { sub.append($0) }
        #expect(sub[0].text == "Doctor")

        var spell: [SSMLNode] = []
        parser.parse(ssml: "<spell>ABC</spell>") { spell.append($0) }
        #expect(spell[0].text == "A B C")
    }

    @Test("phoneme keeps the fallback text and stores the phonemes")
    func testPhonemeFallback() {
        let parser = SSMLParser()
        var nodes: [SSMLNode] = []
        parser.parse(ssml: "<phoneme alphabet=\"ipa\" ph=\"təˈmeɪtoʊ\">tomato</phoneme>") { nodes.append($0) }
        #expect(nodes.count == 1)
        #expect(nodes[0].kind == .phoneme)
        #expect(nodes[0].text == "tomato")
        #expect(nodes[0].phonemes == "təˈmeɪtoʊ")
    }

    @Test("p adds a 300 ms pause after its content")
    func testParagraphPause() {
        let parser = SSMLParser()
        var nodes: [SSMLNode] = []
        parser.parse(ssml: "<speak><p>First.</p><p>Second.</p></speak>") { nodes.append($0) }
        #expect(nodes.count == 4)
        #expect(nodes[1].kind == .pause)
        #expect(nodes[1].pauseMs == 300)
        #expect(nodes[3].kind == .pause)
        #expect(nodes[3].pauseMs == 300)
    }
}