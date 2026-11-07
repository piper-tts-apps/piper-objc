//
//  SSMLParser.swift
//  piper-objc
//
//  Created by Ihor Shevchuk on 2026-03-08.
//
//  SSML-lite port of the Python prototype in workspace/ssml-lite.
//  Supported, in addition to the legacy <prosody rate> path:
//    <break time="500ms" | "1.5s"> and <break strength="weak|medium|strong|...">
//    <prosody rate="x-slow|slow|medium|fast|x-fast"> (multiplier path, see below)
//    <prosody volume="loud|soft|...|125%|0.8">
//    <emphasis level="strong|moderate|reduced|none"> (rate factor, no pitch)
//    <say-as> (parsed, but the inner text is NOT expanded - it passes
//      through unchanged so espeak-ng reads numbers/dates in the
//      voice's own language. English word expansion was removed from
//      PR #21: its hardcoded English word lists would misread in
//      non-English voices. Locale-aware expansion via Foundation
//      spell-out is future work, not in this PR.)
//    <sub alias="...">, <spell>, <p> (300 ms pause after the paragraph)
//    <phoneme alphabet="ipa" ph="..."> (parsed, fallback text is spoken -
//      libpiper cannot inject phonemes directly, see below)
//
//  Deliberately NOT supported, with the same behaviour as the prototype:
//    pitch (VITS has no pitch parameter - ignored, not faked by resampling),
//    <voice>, <lang>, <audio> (no model switch, no network audio),
//    direct <phoneme> injection (libpiper phonemizes text through espeak-ng
//    without the espeakSSML flag, so there is no text path that injects
//    arbitrary phonemes; Piper synthesizes the fallback text instead).
//
//  Rate semantics - read this before changing parseRate / getOptions:
//    The legacy path is VoiceOver-flavoured: <prosody rate="50%"> means
//    normal speed in piper-objc (AV rate 0.5), and Piper.getOptions has a
//    dual AV/multiplier path to handle it. That path is UNCHANGED, so
//    existing VoiceOver behaviour and SSMLParserTests keep passing.
//    SSML-lite named rates (x-slow..x-fast, piper-objc's existing keyword
//    values: 0.5/0.75/1.0/1.5/2.0) take a separate multiplier path: the
//    node keeps the keyword multiplier, and Piper.getOptions converts it
//    as 1/rate, bypassing the AV curve. Without that bypass, "slow" (0.75)
//    would go through the AV curve and come out faster, not slower.
//    Percent/float prosody rates keep the legacy path. Do not merge the
//    two paths without also changing piper-app's AV wrapper, which
//    encodes normal speed as <prosody rate="50%">.
//

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public final class SSMLParser: NSObject {

    // MARK: - Context

    private struct SSMLContext {
        var text: String
        var rate: Float
        /// True when rate is a named-rate multiplier (see header).
        var usesMultiplierPath: Bool
        var volume: Float
        var emphasisFactor: Float
        var element: String
        var subAlias: String?
        var phonemePh: String
        var pauseEmitted: Bool
    }

    // MARK: - State

    private var stack: [SSMLContext] = []
    private var onNode: ((SSMLNode) -> Void)?
    private var ssmlSource: String = ""
    private var ssmlCurrentLocation: String.Index!

    // MARK: - Public API

    public func parse(ssml: String, onNode: @escaping (SSMLNode) -> Void) {
        self.onNode = onNode
        defer { self.onNode = nil }

        guard !ssml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = ssml.data(using: .utf8) else {
            return
        }

        ssmlSource = ssml
        ssmlCurrentLocation = ssmlSource.startIndex

        stack = [
            SSMLContext(text: "", rate: 0.5, usesMultiplierPath: false,
                        volume: 1.0, emphasisFactor: 1.0, element: "",
                        subAlias: nil, phonemePh: "",
                        pauseEmitted: false)
        ]

        let parser = XMLParser(data: data)
        parser.delegate = self

        if !parser.parse() {
            // If parsing fails, treat the whole string as a single text node if it's not just tags.
            if !ssml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onNode(SSMLNode(text: ssml, lengthScale: 1.0, ssmlRange: NSRange(location: 0, length: ssml.utf16.count)))
            }
            return
        }

        flushCurrentText()
    }
}

// MARK: - XMLParserDelegate

extension SSMLParser: XMLParserDelegate {

    public func parser(_ parser: XMLParser,
                       didStartElement elementName: String,
                       namespaceURI: String?,
                       qualifiedName qName: String?,
                       attributes attributeDict: [String: String] = [:]) {

        flushCurrentText()

        let parent = stack.last ?? SSMLContext(text: "", rate: 0.5, usesMultiplierPath: false,
                                               volume: 1.0, emphasisFactor: 1.0, element: "",
                                               subAlias: nil, phonemePh: "",
                                               pauseEmitted: false)
        let element = elementName.lowercased()
        var newContext = SSMLContext(
            text: "",
            rate: parent.rate,
            usesMultiplierPath: parent.usesMultiplierPath,
            volume: parent.volume,
            emphasisFactor: parent.emphasisFactor,
            element: element,
            subAlias: nil,
            phonemePh: "",
            pauseEmitted: false
        )

        switch element {
        case "prosody":
            if let rateStr = attributeDict["rate"] {
                let trimmed = rateStr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let multiplier = Self.namedRates[trimmed] {
                    newContext.usesMultiplierPath = true
                    newContext.rate = multiplier
                } else {
                    newContext.usesMultiplierPath = false
                    newContext.rate = parseRate(rateStr)
                }
            }
            if let volumeStr = attributeDict["volume"] {
                newContext.volume = Self.parseVolume(volumeStr)
            }
            // pitch is intentionally ignored: VITS has no pitch parameter.
        case "emphasis":
            let level = (attributeDict["level"] ?? "moderate").lowercased()
            let factor = Self.emphasisRates[level] ?? 0.95
            newContext.emphasisFactor = parent.emphasisFactor * factor
        case "sub":
            newContext.subAlias = attributeDict["alias"]
        case "phoneme":
            newContext.phonemePh = attributeDict["ph"] ?? ""
        case "break":
            let ms: Int
            if let time = attributeDict["time"] {
                ms = Self.parseTimeMs(time)
            } else {
                let strength = (attributeDict["strength"] ?? "medium").lowercased()
                ms = Self.breakStrengthMs[strength] ?? 400
            }
            // Emit immediately: <break> has no inner text, and its end tag
            // must not emit a second pause.
            onNode?(.pause(milliseconds: ms))
            newContext.pauseEmitted = true
        default:
            break
        }

        stack.append(newContext)
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    public func parser(_ parser: XMLParser,
                       didEndElement elementName: String,
                       namespaceURI: String?,
                       qualifiedName qName: String?) {

        // A break node was already emitted at its start tag.
        if stack.last?.element == "break" {
            if stack.count > 1 { stack.removeLast() }
            return
        }

        flushCurrentText()

        let element = elementName.lowercased()
        if stack.count > 1 {
            stack.removeLast()
        }
        // <p> pauses after its content, matching the prototype.
        if element == "p" {
            onNode?(.pause(milliseconds: 300))
        }
    }
}

// MARK: - Helpers

private extension SSMLParser {

    // piper-objc's existing keyword values (also asserted by
    // PiperLongUtteranceAndBufferTests). The prototype's fast 1.25 /
    // x-fast 1.5 are deliberately NOT used here, to avoid changing
    // existing keyword behaviour in the same PR.
    static let namedRates: [String: Float] = [
        "x-slow": 0.5, "slow": 0.75, "medium": 1.0, "fast": 1.5, "x-fast": 2.0,
    ]
    static let emphasisRates: [String: Float] = [
        "none": 1.0, "moderate": 0.95, "strong": 0.85, "reduced": 1.10,
    ]
    static let breakStrengthMs: [String: Int] = [
        "none": 0, "x-weak": 100, "weak": 200, "medium": 400,
        "strong": 700, "x-strong": 1000,
    ]
    static let volumeNamed: [String: Float] = [
        "silent": 0.0, "x-soft": 0.4, "soft": 0.6, "medium": 1.0,
        "loud": 1.4, "x-loud": 1.8,
    ]

    static func parseTimeMs(_ value: String) -> Int {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasSuffix("ms") {
            return Int(Double(trimmed.dropLast(2)) ?? 400)
        }
        if trimmed.hasSuffix("s") {
            return Int((Double(trimmed.dropLast()) ?? 0.4) * 1000)
        }
        return Int(Double(trimmed) ?? 400)
    }

    static func parseVolume(_ value: String) -> Float {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let named = volumeNamed[trimmed] { return named }
        if trimmed.hasSuffix("%") {
            if let v = Double(trimmed.dropLast()) { return Float(v / 100.0) }
        }
        if let v = Float(trimmed) { return v }
        return 1.0
    }

    func flushCurrentText() {
        guard !stack.isEmpty else { return }

        let context = stack[stack.count - 1]
        let originalText = context.text
        let trimmed = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            stack[stack.count - 1].text = ""
            return
        }

        // Transform the text for synthesis, but look the range up using
        // the original text, which is what actually appears in the source.
        // Expanded text (sub, spell) does not appear verbatim, so
        // searching for it would fail and markers would be lost.
        let spokenText: String
        var kind: SSMLNodeKind = .text
        var phonemes: String? = nil
        switch context.element {
        case "say-as":
            // Deliberately NOT expanded: the inner text passes through
            // unchanged so espeak-ng reads numbers/dates in the voice's
            // own language. See the header comment for why the English
            // word expansion was removed from PR #21.
            spokenText = originalText
        case "sub":
            spokenText = context.subAlias ?? originalText
        case "spell":
            spokenText = originalText.filter { !$0.isWhitespace }.map { String($0) }.joined(separator: " ")
        case "phoneme":
            spokenText = originalText
            kind = .phoneme
            phonemes = context.phonemePh
        default:
            spokenText = originalText
        }
        if spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stack[stack.count - 1].text = ""
            return
        }

        var nsRange = NSRange(location: 0, length: 0)
        let searchText = originalText.precomposedStringWithCanonicalMapping
        if let range = ssmlSource.range(of: searchText, options: [], range: ssmlCurrentLocation..<ssmlSource.endIndex) {
            let location = ssmlSource.distance(from: ssmlSource.startIndex, to: range.lowerBound)
            let length = ssmlSource.distance(from: range.lowerBound, to: range.upperBound)
            nsRange = NSRange(location: location, length: length)
            ssmlCurrentLocation = range.upperBound
        }

        let node = SSMLNode(
            text: spokenText.precomposedStringWithCanonicalMapping,
            lengthScale: context.rate,
            ssmlRange: nsRange,
            kind: kind,
            pauseMs: 0,
            volume: context.volume,
            phonemes: phonemes,
            usesMultiplierPath: context.usesMultiplierPath,
            emphasisFactor: context.emphasisFactor
        )

        onNode?(node)
        stack[stack.count - 1].text = ""
    }

    func parseRate(_ value: String) -> Float {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("%") {
            let rateStr = trimmed.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let rate = Double(rateStr) {
                return Float(rate / 100.0)
            }
        } else {
            // Handle float multiplier like "1.0", "0.5", "2.0", "1"
            if let rate = Float(trimmed) {
                return rate
            }
            // Named rates are handled as the multiplier path in
            // didStartElement and never reach here. Unknown -> 0.5
            // (AV normal), matching the previous behaviour.
            let lower = trimmed.lowercased()
            switch lower {
            case "x-slow": return 0.5
            case "slow": return 0.75
            case "medium": return 1.0
            case "fast": return 1.5
            case "x-fast": return 2.0
            default: break
            }
        }
        return 0.5
    }
}
